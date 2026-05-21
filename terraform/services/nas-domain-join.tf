# =============================================================================
# NAS Domain Join — joins TrueNAS SCALE and Synology DSM to Samba AD
#
# Uses NAS REST APIs to:
#   1. Configure DNS to Pi-hole (required for AD SRV record resolution)
#   2. Join the NAS to the AD domain using domain-join-svc credentials
#   3. Store API keys/credentials in Vault for reuse
#
# Supports: TrueNAS SCALE 25.x+ (/directoryservices API)
#           Synology DSM 7.x (SYNO.Core.Directory.Domain API)
# =============================================================================

locals {
  nas_map = { for nas in var.nas_servers : nas.name => nas }
}

# --- Store NAS credentials in Vault ---

resource "vault_kv_secret_v2" "nas" {
  for_each = var.deploy_samba_ad ? local.nas_map : {}
  mount    = vault_mount.secret.path
  name     = "nas/${each.key}"
  data_json = jsonencode({
    type           = each.value.type
    address        = each.value.address
    api_key        = each.value.api_key
    admin_user     = each.value.admin_user
    admin_password = each.value.admin_password
  })
}

# --- Join NAS servers to AD domain ---

resource "null_resource" "nas_domain_join" {
  for_each = var.deploy_samba_ad ? local.nas_map : {}
  depends_on = [
    nomad_job.samba_ad,
    null_resource.ad_service_accounts,
    vault_kv_secret_v2.samba_ad_accounts,
  ]

  triggers = {
    address  = each.value.address
    type     = each.value.type
    ad_realm = var.ad_realm
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
      NAS_NAME="${each.key}"
      NAS_TYPE="${each.value.type}"
      NAS_ADDR="${each.value.address}"
      AD_REALM="${var.ad_realm}"
      AD_REALM_LOWER=$(echo "$AD_REALM" | tr '[:upper:]' '[:lower:]')
      DNS_IP="${var.dns_server_ip}"

      # Stderr to a debug file so we can see what went wrong despite
      # terraform suppressing output (sensitive vars interpolated below).
      DEBUG_LOG="/tmp/nas_join_$${NAS_NAME}.log"
      exec 2>"$DEBUG_LOG"
      set -x
      echo "=== nas_domain_join $${NAS_NAME} run at $(date) ===" >&2

      # Wait for Vault to be unsealed before reading domain-join creds.
      # See authentik-apps.tf for the same pattern + reasoning.
      echo '[+] Waiting for Vault to be unsealed at ${var.vault_address}...'
      for i in $(seq 1 60); do
        vault_sealed=$(curl -sk --max-time 3 "${var.vault_address}/v1/sys/seal-status" 2>/dev/null \
          | jq -r '.sealed' 2>/dev/null)
        if [ "$vault_sealed" = "false" ]; then
          echo '    Vault unsealed and ready'
          break
        fi
        if [ "$i" = "60" ]; then
          echo '[!] Vault still sealed (or unreachable) after 2 minutes — proceeding anyway'
          break
        fi
        sleep 2
      done

      # Get domain-join credentials from Vault
      DOMAIN_JOIN_PW=$(curl -sk -H "X-Vault-Token: ${var.vault_token}" \
        "${var.vault_address}/v1/secret/data/samba-ad/service-accounts" \
        | jq -r '.data.data.domain_join_password // empty')

      if [ -z "$DOMAIN_JOIN_PW" ]; then
        echo "[!] Could not get domain-join password from Vault"
        exit 1
      fi

      echo "[+] Joining $NAS_TYPE NAS '$NAS_NAME' ($NAS_ADDR) to AD domain $AD_REALM_LOWER..."

      if [ "$NAS_TYPE" = "truenas" ]; then
        # =================================================================
        # TrueNAS SCALE — REST API v2.0
        # =================================================================
        API_KEY="${each.value.api_key}"
        API="https://$NAS_ADDR/api/v2.0"

        # Verify connectivity
        SYS_INFO=$(curl -sk --connect-timeout 10 --max-time 30 \
          -H "Authorization: Bearer $API_KEY" "$API/system/info" 2>/dev/null)
        if [ -z "$SYS_INFO" ] || echo "$SYS_INFO" | jq -e '.error' >/dev/null 2>&1; then
          echo "[!] Cannot reach TrueNAS API at $NAS_ADDR"
          exit 1
        fi
        echo "[+] Connected to TrueNAS $(echo "$SYS_INFO" | jq -r '.version // "unknown"')"

        TRUENAS_HOSTNAME=$(curl -sk -H "Authorization: Bearer $API_KEY" \
          "$API/network/configuration" | jq -r '.hostname // empty')
        HOSTNAME_UPPER=$(echo "$TRUENAS_HOSTNAME" | tr '[:lower:]' '[:upper:]')
        FQDN_LOWER="$(echo "$TRUENAS_HOSTNAME" | tr '[:upper:]' '[:lower:]').$AD_REALM_LOWER"

        # Samba 4.x bumps the machine-account kvno 0 -> 1 during the join,
        # but TrueNAS snapshots the keytab at kvno=0. The join FAILs with
        # KRB5KDC_ERR_PREAUTH_FAILED. Re-export the keytab from the local
        # DC at the current kvno, PUT it into TrueNAS, then retrigger
        # directoryservices to re-sync the keytab DB -> disk.
        apply_kvno_workaround() {
          echo "[!] applying Samba/TrueNAS kvno-mismatch workaround"
          local SAMBA_CID
          # Nomad names docker containers <task>-<alloc_id>; only the
          # alloc_id label is exposed via --filter, so match by name.
          SAMBA_CID=$(docker ps --filter "name=^samba-ad-" --format '{{.ID}}' | head -1)
          if [ -z "$SAMBA_CID" ]; then
            echo "[!] Samba DC container not found on nomad01"; return 1
          fi
          docker exec "$SAMBA_CID" rm -f /tmp/nas.keytab
          local p
          for p in \
            "$HOSTNAME_UPPER\$@$AD_REALM" \
            "HOST/$HOSTNAME_UPPER@$AD_REALM" \
            "HOST/$FQDN_LOWER@$AD_REALM" \
            "RestrictedKrbHost/$HOSTNAME_UPPER@$AD_REALM" \
            "RestrictedKrbHost/$FQDN_LOWER@$AD_REALM" \
            "nfs/$HOSTNAME_UPPER@$AD_REALM" \
            "nfs/$FQDN_LOWER@$AD_REALM"; do
            docker exec "$SAMBA_CID" samba-tool domain exportkeytab \
              /tmp/nas.keytab --principal="$p"
          done
          local KEYTAB_B64
          KEYTAB_B64=$(docker exec "$SAMBA_CID" base64 -w 0 /tmp/nas.keytab)
          docker exec "$SAMBA_CID" rm -f /tmp/nas.keytab
          if [ -z "$KEYTAB_B64" ]; then
            echo "[!] Failed to export keytab from Samba DC"; return 1
          fi
          local KEYTAB_ID
          KEYTAB_ID=$(curl -sk -H "Authorization: Bearer $API_KEY" \
            "$API/kerberos/keytab" \
            | jq -r '.[] | select(.name == "AD_MACHINE_ACCOUNT") | .id')
          local KEYTAB_PAYLOAD
          KEYTAB_PAYLOAD=$(jq -n --arg name "AD_MACHINE_ACCOUNT" --arg file "$KEYTAB_B64" '{name: $name, file: $file}')
          if [ -n "$KEYTAB_ID" ]; then
            curl -sk -X PUT -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
              "$API/kerberos/keytab/id/$KEYTAB_ID" -d "$KEYTAB_PAYLOAD" >/dev/null
          else
            curl -sk -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
              "$API/kerberos/keytab" -d "$KEYTAB_PAYLOAD" >/dev/null
          fi
          # Minimal PUT — TrueNAS rejects it as "Explicit configuration is
          # required", but the side effect re-reads the keytab DB -> disk
          # and flips status to HEALTHY.
          curl -sk -X PUT -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
            "$API/directoryservices" \
            -d '{"service_type":"ACTIVEDIRECTORY","enable":true}' >/dev/null 2>&1 || true
          # cifs stays stopped after the failed join.
          curl -sk -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
            "$API/service/start" -d '{"service":"cifs"}' >/dev/null 2>&1 || true
          # 5 min — recovery from a long FAULTED self-heal loop can take
          # several minutes for cache/idmap to settle after the keytab swap.
          local i STATUS=unknown
          for i in $(seq 1 60); do
            STATUS=$(curl -sk -H "Authorization: Bearer $API_KEY" \
              "$API/directoryservices/status" | jq -r '.status // "unknown"')
            if [ "$STATUS" = "HEALTHY" ]; then
              echo "[+] directoryservices status HEALTHY"; return 0
            fi
            sleep 5
          done
          echo "[!] kvno workaround applied but directoryservices not HEALTHY after 5 min (status=$STATUS)"
          return 1
        }

        # Check if already joined
        AD_STATUS=$(curl -sk -H "Authorization: Bearer $API_KEY" "$API/directoryservices" 2>/dev/null)
        AD_ENABLED=$(echo "$AD_STATUS" | jq -r 'if (.service_type == "ACTIVEDIRECTORY" and .enable == true) then "true" else "false" end' 2>/dev/null)

        if [ "$AD_ENABLED" = "true" ]; then
          CURRENT_DOMAIN=$(echo "$AD_STATUS" | jq -r '.configuration.domain // "unknown"')
          HEALTH=$(curl -sk -H "Authorization: Bearer $API_KEY" \
            "$API/directoryservices/status" | jq -r '.status // "unknown"')
          if [ "$HEALTH" = "HEALTHY" ]; then
            echo "[+] TrueNAS already joined to $CURRENT_DOMAIN (HEALTHY) — skipping"
            exit 0
          fi
          # FAULTED with enable=true is the kvno-mismatch post-state:
          # the join already created the AD-side machine account at
          # kvno=1; the keytab in TrueNAS is stuck at kvno=0. Re-export
          # the keytab from the DC and PUT it back; no re-join needed.
          echo "[!] TrueNAS joined to $CURRENT_DOMAIN but status=$HEALTH"
          apply_kvno_workaround || exit 1
          exit 0
        fi

        # Configure DNS to Pi-hole (required for AD SRV records)
        echo "[+] Setting DNS to Pi-hole ($DNS_IP)..."
        curl -sk -X PUT -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
          "$API/network/configuration" \
          -d "{\"nameserver1\":\"$DNS_IP\",\"nameserver2\":\"\",\"nameserver3\":\"\"}" >/dev/null

        # Ensure Kerberos realm exists
        echo "[+] Registering Kerberos realm..."
        REALM_EXISTS=$(curl -sk -H "Authorization: Bearer $API_KEY" "$API/kerberos/realm" \
          | jq -r --arg r "$AD_REALM" 'any(.realm == $r)')
        if [ "$REALM_EXISTS" != "true" ]; then
          curl -sk -X POST -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
            "$API/kerberos/realm" -d "{\"realm\":\"$AD_REALM\"}" >/dev/null
        fi

        # Join AD
        # Target OU=Workstations for the machine account: domain-join-svc
        # was granted CreateChild rights there in samba-ad-accounts.tf, so
        # creating a machine account in the default CN=Computers fails with
        # "Insufficient access" / WERR_ACCESS_DENIED. Setting computer_account_ou
        # routes the join to the correct OU.
        echo "[+] Joining AD domain (this may take 30-60s)..."
        COMPUTER_OU="OU=Workstations,${local.ad_base_dn}"
        JOIN_PAYLOAD=$(jq -n \
          --arg realm "$AD_REALM" \
          --arg domain "$AD_REALM_LOWER" \
          --arg pw "$DOMAIN_JOIN_PW" \
          --arg host "$HOSTNAME_UPPER" \
          --arg ou "$COMPUTER_OU" \
          '{
            service_type: "ACTIVEDIRECTORY",
            credential: {credential_type: "KERBEROS_USER", username: "domain-join-svc", password: $pw},
            kerberos_realm: $realm,
            configuration: {
              service_type: "ACTIVEDIRECTORY",
              hostname: $host,
              domain: $domain,
              computer_account_ou: $ou
            },
            enable: true
          }')

        JOB_ID=$(curl -sk -X PUT -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
          "$API/directoryservices" -d "$JOIN_PAYLOAD" 2>/dev/null)

        if [[ "$JOB_ID" =~ ^[0-9]+$ ]]; then
          # Poll job status
          WAITED=0
          while [ $WAITED -lt 180 ]; do
            STATE=$(curl -sk -H "Authorization: Bearer $API_KEY" \
              "$API/core/get_jobs?id=$JOB_ID" | jq -r '.[0].state // "UNKNOWN"')
            case "$STATE" in
              SUCCESS) echo "[+] TrueNAS joined to AD: $AD_REALM_LOWER"; break ;;
              FAILED)
                ERR=$(curl -sk -H "Authorization: Bearer $API_KEY" \
                  "$API/core/get_jobs?id=$JOB_ID" | jq -r '.[0].error // "unknown"')
                if echo "$ERR" | grep -qi PREAUTH; then
                  echo "[!] AD join PREAUTH-failed (kvno mismatch)"
                  apply_kvno_workaround || exit 1
                  echo "[+] TrueNAS joined to AD: $AD_REALM_LOWER (via kvno workaround)"
                  break
                fi
                echo "[!] AD join failed: $ERR"; exit 1 ;;
              *) sleep 5; WAITED=$((WAITED + 5)) ;;
            esac
          done
          if [ $WAITED -ge 180 ]; then echo "[!] AD join timed out after 180s"; exit 1; fi
        else
          echo "[!] AD join failed: $(echo "$JOB_ID" | jq -r '.message // .error // "unknown"' 2>/dev/null)"
          exit 1
        fi

      elif [ "$NAS_TYPE" = "synology" ]; then
        # =================================================================
        # Synology DSM 7.x — SYNO.* Web API
        # =================================================================
        ADMIN_USER="${each.value.admin_user}"
        ADMIN_PASS="${each.value.admin_password}"
        API="https://$NAS_ADDR:5001/webapi"

        # Authenticate to DSM
        echo "[+] Authenticating to Synology DSM..."
        LOGIN_RESP=$(curl -sk --connect-timeout 10 --max-time 30 -X POST \
          "$API/entry.cgi" \
          -d "api=SYNO.API.Auth&version=7&method=login&format=sid" \
          --data-urlencode "account=$ADMIN_USER" \
          --data-urlencode "passwd=$ADMIN_PASS" 2>/dev/null)
        SID=$(echo "$LOGIN_RESP" | jq -r '.data.sid // empty')

        if [ -z "$SID" ]; then
          echo "[!] Synology login failed: $(echo "$LOGIN_RESP" | jq -r '.error // .')"
          exit 1
        fi
        echo "[+] Authenticated to Synology DSM"

        # Check current domain status
        echo "[+] Checking current domain status..."
        DOMAIN_STATUS=$(curl -sk \
          "$API/entry.cgi?api=SYNO.Core.Directory.Domain&version=1&method=get&_sid=$SID" 2>/dev/null)
        DOMAIN_ENABLED=$(echo "$DOMAIN_STATUS" | jq -r '.data.enable // false')

        if [ "$DOMAIN_ENABLED" = "true" ]; then
          CURRENT=$(echo "$DOMAIN_STATUS" | jq -r '.data.domain_name // "unknown"')
          echo "[+] Synology already joined to: $CURRENT — skipping"
          # Logout
          curl -sk "$API/auth.cgi?api=SYNO.API.Auth&version=7&method=logout&_sid=$SID" >/dev/null 2>&1
          exit 0
        fi

        # Configure DNS to Pi-hole (required for AD SRV record resolution)
        echo "[+] Setting DNS to Pi-hole ($DNS_IP)..."
        curl -sk -X POST "$API/entry.cgi" \
          -d "api=SYNO.Core.Network&version=1&method=set&_sid=$SID" \
          -d "dns_manual=true" \
          -d "dns_primary=$DNS_IP" >/dev/null 2>&1 || echo "[!] DNS config may need manual setup"

        # Join AD domain (admin_name/admin_passwd = domain join credentials, not DSM creds)
        echo "[+] Joining AD domain $AD_REALM_LOWER..."
        JOIN_RESP=$(curl -sk -X POST "$API/entry.cgi" \
          -d "api=SYNO.Core.Directory.Domain&version=1&method=set&_sid=$SID" \
          -d "domain_name=$AD_REALM_LOWER" \
          -d "admin_name=domain-join-svc" \
          -d "admin_passwd=$DOMAIN_JOIN_PW" \
          -d "dns_server=$DNS_IP" \
          -d "enable=true" 2>/dev/null)
        JOIN_SUCCESS=$(echo "$JOIN_RESP" | jq -r '.success // false')

        if [ "$JOIN_SUCCESS" != "true" ]; then
          ERR_CODE=$(echo "$JOIN_RESP" | jq -r '.error.code // "unknown"')
          echo "[!] AD join request failed (error code: $ERR_CODE)"
          echo "[!] Full response: $(echo "$JOIN_RESP" | jq -c .)"
          curl -sk "$API/entry.cgi?api=SYNO.API.Auth&version=7&method=logout&_sid=$SID" >/dev/null 2>&1
          exit 1
        fi

        # Poll for join completion (async operation)
        echo "[+] Waiting for domain join to complete..."
        WAITED=0
        while [ $WAITED -lt 120 ]; do
          VERIFY=$(curl -sk \
            "$API/entry.cgi?api=SYNO.Core.Directory.Domain&version=1&method=get&_sid=$SID" 2>/dev/null)
          STATUS=$(echo "$VERIFY" | jq -r '.data.status // "unknown"')
          if [ "$STATUS" = "domain_joined" ]; then
            echo "[+] Synology joined to AD: $AD_REALM_LOWER"
            break
          fi
          sleep 5
          WAITED=$((WAITED + 5))
        done
        [ $WAITED -ge 120 ] && echo "[!] Join verification timed out — check Synology DSM UI"

        # Logout
        curl -sk "$API/entry.cgi?api=SYNO.API.Auth&version=7&method=logout&_sid=$SID" >/dev/null 2>&1

      else
        echo "[!] Unknown NAS type: $NAS_TYPE (expected 'truenas' or 'synology')"
        exit 1
      fi

      echo "[+] NAS domain join complete: $NAS_NAME ($NAS_TYPE)"
      EOT
    ]
  }
}
