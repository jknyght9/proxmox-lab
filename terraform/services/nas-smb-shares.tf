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
    grace_period = optional(number, 0)        # TIME_LOCKED_SHARE only — seconds before file locks read-only (WORM)
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

      # base64-pipe avoids Terraform's heredoc interpreting escape sequences
      # (e.g., \n in jsonencode output gets turned into real newlines, which
      # then break the inner jq parse). base64 has no control chars.
      SHARES_JSON=$(echo '${base64encode(jsonencode(each.value))}' | base64 -d)

      echo "[+] Provisioning SMB shares on $NAS_NAME ($NAS_ADDR)"

      # Fetch existing shares once, look up by name in the loop
      EXISTING=$(auth "$API/sharing/smb")

      # Write share list to a temp file and read via redirect — avoids the
      # pipe-subshell pattern (where set -e + exit 1 inside the loop die
      # in the subshell and the parent script reports success). nomad01's
      # /bin/sh is dash, which also lacks process substitution.
      SHARES_LIST=$(mktemp)
      echo "$SHARES_JSON" | jq -c '.[]' > "$SHARES_LIST"
      echo "    [i] $(wc -l < "$SHARES_LIST") shares to process"

      while read -r share; do
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
        GRACE_PERIOD=$(echo "$share" | jq -r '.grace_period // 0')
        PURPOSE=$(echo "$share" | jq -r '.purpose // "DEFAULT_SHARE"')

        # TrueNAS rejects audit.enable=true with both lists empty AND the
        # list entries must be SMB-recognized groups (not Unix users).
        # builtin_users is the local Samba group every authenticated SMB
        # session is a member of, so watch_list=["builtin_users"]
        # effectively audits everyone.
        AUDIT_WATCH='[]'
        if [ "$AUDIT" = "true" ]; then
          AUDIT_WATCH='["builtin_users"]'
        fi

        # TrueNAS 25.x: hostsallow, grace_period, and aapl_name_mangling
        # live nested under "options". Top-level only: name, path, comment,
        # purpose, enabled, readonly, browsable, access_based_share_enumeration,
        # audit. Other fields (ro, guestok, home) appear to be implicit from
        # purpose preset and don't have to be sent.
        OPTIONS_JSON=$(jq -n \
          --argjson hosts_allow "$HOSTS_ALLOW" \
          --argjson grace_period "$GRACE_PERIOD" '
          {hostsallow: $hosts_allow, hostsdeny: []}
          + (if $grace_period > 0 then {grace_period: $grace_period} else {} end)
          ')

        PAYLOAD=$(jq -n \
          --arg name "$NAME" \
          --arg path "$SHARE_PATH" \
          --arg comment "$COMMENT" \
          --argjson enabled "$ENABLED" \
          --argjson readonly "$RO" \
          --argjson browsable "$BROWSABLE" \
          --argjson abe "$ABE" \
          --argjson audit_enable "$AUDIT" \
          --argjson audit_watch "$AUDIT_WATCH" \
          --arg purpose "$PURPOSE" \
          --argjson options "$OPTIONS_JSON" '{
            name: $name,
            path: $path,
            comment: $comment,
            purpose: $purpose,
            enabled: $enabled,
            readonly: $readonly,
            browsable: $browsable,
            access_based_share_enumeration: $abe,
            audit: { enable: $audit_enable, watch_list: $audit_watch, ignore_list: [] },
            options: $options
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

        # TrueNAS success returns the full share object (always has .id).
        # Failures come in many shapes (nested per-field, top-level error,
        # plain string). Check for the success signal instead of trying to
        # enumerate every error shape.
        RESULT_ID=$(echo "$RESP" | jq -r '.id // empty' 2>/dev/null)
        if [ -z "$RESULT_ID" ]; then
          echo "[!] share configure failed for $NAME: $(echo "$RESP" | head -c 500)"
          exit 1
        fi
        echo "        -> id=$RESULT_ID"
      done < "$SHARES_LIST"
      rm -f "$SHARES_LIST"

      echo "[+] $NAS_NAME SMB shares done"
      EOT
    ]
  }
}
