# =============================================================================
# Authentik AD Sync — configured via API
#
# Creates an LDAP source in Authentik that syncs users/groups from Samba AD.
# Uses the authentik-sync service account created by samba-ad-accounts.tf.
# =============================================================================

resource "null_resource" "authentik_ad_sync" {
  count = var.configure_authentik && var.deploy_samba_ad ? 1 : 0
  depends_on = [
    null_resource.ad_service_accounts,
    nomad_job.authentik,
  ]

  triggers = {
    ad_realm    = var.ad_realm
    dns_postfix = var.dns_postfix
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
      API="https://${local.nomad01_ip}:9443/api/v3"
      TOKEN="${var.authentik_api_token}"
      BASE_DN="${local.ad_base_dn}"
      SYNC_DN="CN=authentik-sync,CN=Users,$BASE_DN"
      SYNC_PW='${random_password.authentik_sync[0].result}'

      echo '[+] Configuring Authentik AD sync via API...'

      # Check if LDAP source already exists
      # NOTE: Authentik API slug filter doesn't do exact match — filter client-side
      EXISTING=$(curl -sk -H "Authorization: Bearer $TOKEN" \
        "$API/sources/ldap/" | jq -r '[.results[] | select(.slug == "samba-ad")][0].pk // empty')

      if [ -n "$EXISTING" ]; then
        echo "[+] AD LDAP source already exists (pk=$EXISTING)"
      else
        # Get AD property mapping PKs (ms-* and default, not OpenLDAP)
        USER_MAPPINGS=$(curl -sk -H "Authorization: Bearer $TOKEN" \
          "$API/propertymappings/source/ldap/" \
          | jq -c '[.results[] | select(.managed | test("ms-|default-")) | .pk]')
        GROUP_MAPPINGS=$(curl -sk -H "Authorization: Bearer $TOKEN" \
          "$API/propertymappings/source/ldap/" \
          | jq -c '[.results[] | select(.managed | test("default-")) | .pk]')

        echo '[+] Creating Samba AD LDAP source...'
        curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
          -X POST "$API/sources/ldap/" \
          -d "{
            \"name\": \"Samba AD\",
            \"slug\": \"samba-ad\",
            \"server_uri\": \"ldap://${local.nomad01_ip}\",
            \"bind_cn\": \"$SYNC_DN\",
            \"bind_password\": \"$SYNC_PW\",
            \"base_dn\": \"$BASE_DN\",
            \"start_tls\": false,
            \"sync_users\": true,
            \"sync_groups\": true,
            \"sync_users_password\": true,
            \"user_property_mappings\": $USER_MAPPINGS,
            \"group_property_mappings\": $GROUP_MAPPINGS,
            \"user_object_filter\": \"(&(objectClass=user)(!(objectClass=computer)))\",
            \"group_object_filter\": \"(objectClass=group)\",
            \"object_uniqueness_field\": \"objectSid\",
            \"group_membership_field\": \"member\",
            \"enabled\": true
          }" | jq -r '.slug'
        echo '[+] Samba AD LDAP source created'
      fi
      EOT
    ]
  }
}
