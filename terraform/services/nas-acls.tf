# =============================================================================
# NAS ACLs — share-level + dataset NFSv4 ACLs
#
# Two ACL layers per share, both applied via the TrueNAS REST API:
#
#   1. Share-level ACL (POST /sharing/smb/setacl):
#      Gates "can this connection authenticate to the share at all".
#      Used to enforce the single caveat per share per the data
#      classification policy (e.g., Caveat-USO on heavy-metal/snl).
#
#   2. Dataset-level NFSv4 ACL (POST /filesystem/setacl):
#      Gates "what operations the authenticated user can do on files".
#      Used for project role groups (Read/Write/Admin).
#
#   Effective access = intersection of share ACL and dataset ACL —
#   which is exactly how the one-caveat layered model is enforced.
#
# Async note: filesystem/setacl returns a job id on SCALE 25.x — poll
# /core/get_jobs until SUCCESS/FAILED.
#
# Lab-specific ACL list lives in a lab-extensions overlay
# (lab-nas-acls.auto.tfvars).
# =============================================================================

variable "nas_acls" {
  description = "Per-share ACL definitions: share-level ACL + dataset NFSv4 ACL."
  type = list(object({
    nas   = string # NAS name from var.nas_servers
    share = string # share name (used to look up share for setacl call)
    path  = string # /mnt-prefixed dataset path (filesystem/setacl target)

    # Share-level ACL — gates connection
    share_acl = optional(list(object({
      who  = string                      # group/user name (e.g. "Caveat-USO", "everyone@")
      perm = string                      # FULL | CHANGE | READ
      type = optional(string, "ALLOWED") # ALLOWED | DENIED
    })), [])

    # Dataset NFSv4 ACL — gates filesystem operations.
    # Empty list = skip (use when multiple shares point at the same
    # dataset; set the ACL via one share's entry only).
    dataset_acl = optional(list(object({
      tag   = string                           # owner@ | group@ | everyone@ | USER | GROUP
      name  = optional(string)                 # required when tag is USER or GROUP
      type  = optional(string, "ALLOW")        # ALLOW | DENY
      perms = optional(string, "FULL_CONTROL") # FULL_CONTROL | MODIFY | READ | TRAVERSE
      flags = optional(string, "INHERIT")      # INHERIT | NOINHERIT | INHERIT_ONLY
    })), [])
  }))
  default = []
}

locals {
  acls_by_nas = {
    for a in var.nas_acls : a.nas => a...
  }
}

resource "null_resource" "nas_acls" {
  for_each = local.acls_by_nas

  depends_on = [
    null_resource.nas_smb_shares,
    null_resource.ad_groups,
  ]

  triggers = {
    acls_hash   = sha256(jsonencode(each.value))
    nas_address = local.nas_by_name[each.key].address
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e
      NAS_NAME='${each.key}'
      NAS_ADDR='${local.nas_by_name[each.key].address}'
      API_KEY='${local.nas_by_name[each.key].api_key}'
      API="https://$NAS_ADDR/api/v2.0"

      auth() { curl -sk -H "Authorization: Bearer $API_KEY" "$@"; }

      # base64 + temp file pattern — same as nas-smb-shares (see notes there)
      ACLS_JSON=$(echo '${base64encode(jsonencode(each.value))}' | base64 -d)

      echo "[+] Applying ACLs on $NAS_NAME ($NAS_ADDR)"

      ACLS_LIST=$(mktemp)
      echo "$ACLS_JSON" | jq -c '.[]' > "$ACLS_LIST"

      while read -r acl; do
        SHARE_NAME=$(echo "$acl" | jq -r '.share')
        SHARE_PATH=$(echo "$acl" | jq -r '.path')
        echo "  [$SHARE_NAME] $SHARE_PATH"

        # --- Share-level ACL ---
        SHARE_ACL=$(echo "$acl" | jq -c '.share_acl // []')
        if [ "$SHARE_ACL" != "[]" ]; then
          SHARE_ACL_PAYLOAD=$(echo "$SHARE_ACL" | jq --arg name "$SHARE_NAME" '{
            share_name: $name,
            share_acl: [.[] | {
              ae_who_str: .who,
              ae_perm: .perm,
              ae_type: (.type // "ALLOWED")
            }]
          }')
          RESP=$(auth -X POST -H "Content-Type: application/json" \
            "$API/sharing/smb/setacl" -d "$SHARE_ACL_PAYLOAD")
          if [ -n "$RESP" ] && echo "$RESP" | jq -e '.error // .errno' >/dev/null 2>&1; then
            echo "[!] share ACL failed for $SHARE_NAME: $(echo "$RESP" | head -c 500)"
            exit 1
          fi
          echo "    -> share_acl: $(echo "$SHARE_ACL" | jq -c '[.[] | .who]')"
        fi

        # --- Dataset NFSv4 ACL ---
        DATASET_ACL=$(echo "$acl" | jq -c '.dataset_acl // []')
        if [ "$DATASET_ACL" != "[]" ]; then
          DATASET_ACL_PAYLOAD=$(echo "$DATASET_ACL" | jq --arg path "$SHARE_PATH" '{
            path: $path,
            dacl: [.[] | {
              tag: .tag,
              name: (if (.name // "") != "" then .name else null end),
              id: null,
              type: (.type // "ALLOW"),
              perms: { BASIC: (.perms // "FULL_CONTROL") },
              flags: { BASIC: (.flags // "INHERIT") }
            }],
            options: {stripacl: false, recursive: false, traverse: false},
            acltype: "NFS4"
          }')
          ACL_JOB=$(auth -X POST -H "Content-Type: application/json" \
            "$API/filesystem/setacl" -d "$DATASET_ACL_PAYLOAD")

          if echo "$ACL_JOB" | grep -qE '^[0-9]+$'; then
            # Async job — poll
            for i in $(seq 1 30); do
              STATE=$(auth "$API/core/get_jobs?id=$ACL_JOB" | jq -r '.[0].state // "UNKNOWN"')
              case "$STATE" in
                SUCCESS) break ;;
                FAILED)
                  ERR=$(auth "$API/core/get_jobs?id=$ACL_JOB" | jq -r '.[0].error // "unknown"')
                  echo "[!] dataset ACL job failed for $SHARE_PATH: $ERR"
                  exit 1
                  ;;
                *) sleep 2 ;;
              esac
            done
          elif echo "$ACL_JOB" | jq -e '.error // .errno' >/dev/null 2>&1; then
            echo "[!] dataset ACL failed for $SHARE_PATH: $(echo "$ACL_JOB" | head -c 500)"
            exit 1
          fi
          echo "    -> dataset_acl: $(echo "$DATASET_ACL" | jq -c '[.[] | "\(.tag):\(.name // "-"):\(.perms // "FULL")"]')"
        fi
      done < "$ACLS_LIST"
      rm -f "$ACLS_LIST"

      echo "[+] $NAS_NAME ACLs done"
      EOT
    ]
  }
}
