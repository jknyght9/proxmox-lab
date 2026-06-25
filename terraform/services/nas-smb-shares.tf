# =============================================================================
# NAS SMB Shares — declarative SMB share provisioning on TrueNAS NASes
#
# Accepts var.nas_shares (list of share definitions) and creates/updates
# each via the TrueNAS REST API. Idempotent: GET /sharing/smb to find
# existing by name, PUT if exists else POST.
#
# Phase 4 intent: shares are typically created with enabled=false so they
# exist but cannot be connected to; ACLs land in Phase 5; enabled=true
# is flipped in Phase 8 once access is verified.
#
# Lab-specific share list lives in a lab-extensions overlay
# (lab-nas-smb-shares.auto.tfvars).
# =============================================================================

variable "nas_shares" {
  description = "SMB shares to provision on TrueNAS NASes (capability is consumed by a lab-extensions overlay)."
  type = list(object({
    nas          = string                     # NAS name from var.nas_servers
    name         = string                     # share name (visible to clients as \\nas\<name>)
    path         = string                     # /mnt-prefixed filesystem path
    comment      = optional(string, "")       # human-readable description
    enabled      = optional(bool, false)      # default disabled — Phase 4 creates shares dark
    ro           = optional(bool, false)      # read-only at the share layer
    guestok      = optional(bool, false)      # allow anonymous (PUBLIC tier only)
    browsable    = optional(bool, true)       # show in network browse
    abe          = optional(bool, true)       # access-based enumeration
    audit        = optional(bool, false)      # SMB audit logging (required for CONFIDENTIAL+ per policy)
    hosts_allow  = optional(list(string), []) # IPs/hostnames that may connect (empty = any)
    aux_smb_conf = optional(string, "")       # raw Samba aux params (vfs_worm, etc.)
    purpose      = optional(string, "DEFAULT_SHARE")
  }))
  default = []
}

locals {
  # Group shares by target NAS — one null_resource per NAS
  shares_by_nas = {
    for s in var.nas_shares : s.nas => s...
  }
}

resource "null_resource" "nas_smb_shares" {
  for_each = local.shares_by_nas

  depends_on = [
    null_resource.nas_classification_datasets,
  ]

  triggers = {
    shares_hash = sha256(jsonencode(each.value))
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

      SHARES_JSON='${jsonencode(each.value)}'

      echo "[+] Provisioning SMB shares on $NAS_NAME ($NAS_ADDR)"

      # Fetch existing shares once, look up by name in the loop
      EXISTING=$(auth "$API/sharing/smb")

      echo "$SHARES_JSON" | jq -c '.[]' | while read -r share; do
        NAME=$(echo "$share" | jq -r '.name')
        SHARE_PATH=$(echo "$share" | jq -r '.path')
        COMMENT=$(echo "$share" | jq -r '.comment // ""')
        ENABLED=$(echo "$share" | jq -r '.enabled // false')
        RO=$(echo "$share" | jq -r '.ro // false')
        GUESTOK=$(echo "$share" | jq -r '.guestok // false')
        BROWSABLE=$(echo "$share" | jq -r '.browsable // true')
        ABE=$(echo "$share" | jq -r '.abe // true')
        AUDIT=$(echo "$share" | jq -r '.audit // false')
        HOSTS_ALLOW=$(echo "$share" | jq -c '.hosts_allow // []')
        AUX_SMB_CONF=$(echo "$share" | jq -r '.aux_smb_conf // ""')
        PURPOSE=$(echo "$share" | jq -r '.purpose // "DEFAULT_SHARE"')

        PAYLOAD=$(jq -n \
          --arg name "$NAME" \
          --arg path "$SHARE_PATH" \
          --arg comment "$COMMENT" \
          --argjson enabled "$ENABLED" \
          --argjson ro "$RO" \
          --argjson guestok "$GUESTOK" \
          --argjson browsable "$BROWSABLE" \
          --argjson abe "$ABE" \
          --argjson audit_enable "$AUDIT" \
          --argjson hosts_allow "$HOSTS_ALLOW" \
          --arg aux "$AUX_SMB_CONF" \
          --arg purpose "$PURPOSE" '{
            name: $name,
            path: $path,
            comment: $comment,
            purpose: $purpose,
            enabled: $enabled,
            ro: $ro,
            guestok: $guestok,
            browsable: $browsable,
            abe: $abe,
            home: false,
            hostsallow: $hosts_allow,
            auxsmbconf: $aux,
            audit: { enable: $audit_enable, watch_list: [], ignore_list: [] }
          }')

        SHARE_ID=$(echo "$EXISTING" | jq -r --arg n "$NAME" '.[] | select(.name == $n) | .id // empty')

        if [ -n "$SHARE_ID" ]; then
          echo "    [=] $NAME (id=$SHARE_ID) — updating"
          RESP=$(auth -X PUT -H "Content-Type: application/json" \
            "$API/sharing/smb/id/$SHARE_ID" -d "$PAYLOAD")
        else
          echo "    [+] $NAME — creating (enabled=$ENABLED)"
          RESP=$(auth -X POST -H "Content-Type: application/json" \
            "$API/sharing/smb" -d "$PAYLOAD")
        fi

        if echo "$RESP" | jq -e '.error // .errno' >/dev/null 2>&1; then
          echo "[!] share configure failed for '$NAME': $(echo "$RESP" | jq -c .)"
          exit 1
        fi
      done

      echo "[+] $NAS_NAME SMB shares done"
      EOT
    ]
  }
}
