# =============================================================================
# Authentik Applications & Providers — configured via API
#
# NOTE: The goauthentik/authentik Terraform provider has bugs with
# invalidation_flow on OAuth2/LDAP providers. All Authentik configuration
# is done via the REST API using null_resource + curl instead.
#
# Access control:
# - All users: Kasm (LDAP, see authentik-ldap.tf)
# - Admins only: Pi-hole, Traefik, Vault, Nomad, Uptime Kuma, LAM
# =============================================================================

resource "null_resource" "authentik_apps" {
  count      = var.configure_authentik ? 1 : 0
  depends_on = [nomad_job.authentik]

  triggers = {
    dns_postfix      = var.dns_postfix
    deploy_uptime    = var.deploy_uptime_kuma
    deploy_lam       = var.deploy_lam
    deploy_netbox    = var.deploy_netbox
    deploy_unifi_dns = var.deploy_unifi_dns
    deploy_forgejo   = var.deploy_forgejo
    deploy_kaneo     = var.deploy_kaneo
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

      # Wait for Vault to be unsealed before any vault_address calls
      # (OIDC client_secret writes for Vault and Netbox land in Vault
      # near the end of this script). Mirrors the wait-for-gluster
      # pattern in Nomad jobs — bash provisioners have no built-in
      # retry budget, so a 503-sealed response from a freshly-restarted
      # Vault would crash `set -e` mid-script with a confusing error.
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

      # Self-heal: Authentik's "authentik-bootstrap-token" row in postgres
      # only honours AUTHENTIK_BOOTSTRAP_TOKEN on first DB init. If a later
      # deploy regenerates random_password.authentik_api_token (state wipe,
      # Vault re-init, manual rotation), Vault holds the new value but the
      # Authentik DB still has the old one — every subsequent API call
      # returns 403, jq trips on null .results, the script exits 5.
      # Sync the DB row to match Vault before any API call so the deploy
      # is idempotent across re-runs.
      echo '[+] Verifying Authentik bootstrap token matches Vault...'
      ALLOC_ID=$(nomad job status authentik 2>/dev/null | awk '/run +running/ {print $1; exit}')
      if [ -z "$ALLOC_ID" ]; then
        echo "    [!] No running authentik alloc — skipping self-heal (API calls below will fail loudly if drift exists)"
      else
        DB_TOKEN=$(nomad alloc exec -task postgres "$ALLOC_ID" \
          psql -U authentik -d authentik -t -A -c \
          "SELECT key FROM authentik_core_token WHERE identifier='authentik-bootstrap-token';" \
          2>/dev/null | tr -d '[:space:]')
        if [ -z "$DB_TOKEN" ]; then
          echo "    [!] Could not read bootstrap token from postgres yet — Authentik may still be migrating; skipping self-heal"
        elif [ "$DB_TOKEN" = "$TOKEN" ]; then
          echo "    Token already matches Vault"
        else
          echo "    Drift detected — UPDATEing Authentik DB to match Vault"
          nomad alloc exec -task postgres "$ALLOC_ID" \
            psql -U authentik -d authentik -c \
            "UPDATE authentik_core_token SET key='$TOKEN' WHERE identifier='authentik-bootstrap-token';" \
            > /dev/null
          echo "    Token synced"
        fi
      fi

      echo '[+] Configuring Authentik applications via API...'

      # Helper: create or get resource by name/slug
      # NOTE: Authentik API name/slug filter doesn't do exact match — it returns
      # all results. Must filter client-side with jq.
      create_or_get() {
        local endpoint="$1" name_field="$2" name_value="$3" payload="$4"
        local existing
        if [ "$name_field" = "slug" ]; then
          existing=$(curl -sk -H "Authorization: Bearer $TOKEN" \
            "$API/$endpoint/" \
            | jq -r --arg v "$name_value" '[.results[] | select(.slug == $v)][0].pk // empty')
        else
          existing=$(curl -sk -H "Authorization: Bearer $TOKEN" \
            "$API/$endpoint/" \
            | jq -r --arg v "$name_value" '[.results[] | select(.name == $v)][0].pk // empty')
        fi
        if [ -n "$existing" ]; then
          echo "$existing"
        else
          curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
            -X POST "$API/$endpoint/" -d "$payload" | jq -r '.pk'
        fi
      }

      # Get default flows
      AUTH_FLOW=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/flows/instances/" | jq -r '[.results[] | select(.slug == "default-authentication-flow")][0].pk')
      AUTHZ_FLOW=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/flows/instances/" | jq -r '[.results[] | select(.slug == "default-provider-authorization-implicit-consent")][0].pk')
      INVAL_FLOW=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/flows/instances/" | jq -r '[.results[] | select(.slug == "default-invalidation-flow")][0].pk')

      echo "    Flows loaded"

      # App icon base URL (homarr-labs/dashboard-icons)
      ICON="https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main"

      # --- Proxy Providers + Applications ---
      echo '[+] Proxy providers + applications...'

      # Collect proxy provider PKs for embedded outpost assignment
      PROXY_PKS=""

      PIHOLE_PK=$(create_or_get "providers/proxy" "name" "Pi-hole" \
        "{\"name\":\"Pi-hole\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"mode\":\"forward_single\",\"external_host\":\"https://pihole.${var.dns_postfix}\"}")
      create_or_get "core/applications" "slug" "pihole" \
        "{\"name\":\"Pi-hole\",\"slug\":\"pihole\",\"provider\":$PIHOLE_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://pihole.${var.dns_postfix}/admin/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/pi-hole.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null
      PROXY_PKS="$PIHOLE_PK"

      TRAEFIK_PK=$(create_or_get "providers/proxy" "name" "Traefik" \
        "{\"name\":\"Traefik\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"mode\":\"forward_single\",\"external_host\":\"https://traefik.${var.dns_postfix}\"}")
      create_or_get "core/applications" "slug" "traefik" \
        "{\"name\":\"Traefik\",\"slug\":\"traefik\",\"provider\":$TRAEFIK_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://traefik.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/traefik-proxy.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null
      PROXY_PKS="$PROXY_PKS,$TRAEFIK_PK"

      NOMAD_PK=$(create_or_get "providers/proxy" "name" "Nomad" \
        "{\"name\":\"Nomad\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"mode\":\"forward_single\",\"external_host\":\"https://nomad.${var.dns_postfix}\"}")
      create_or_get "core/applications" "slug" "nomad" \
        "{\"name\":\"Nomad\",\"slug\":\"nomad\",\"provider\":$NOMAD_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://nomad.${var.dns_postfix}/ui/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/hashicorp-nomad.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null
      PROXY_PKS="$PROXY_PKS,$NOMAD_PK"

      # --- Vault OIDC ---
      echo '[+] Vault OIDC provider...'
      CERT_PK=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/crypto/certificatekeypairs/" | jq -r '[.results[] | select(.name == "authentik Self-signed Certificate")][0].pk // empty')

      VAULT_PK=$(create_or_get "providers/oauth2" "name" "Vault" \
        "{\"name\":\"Vault\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"client_type\":\"confidential\",\"client_id\":\"vault\",\"signing_key\":\"$CERT_PK\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"https://vault.${var.dns_postfix}/ui/vault/auth/oidc/oidc/callback\"},{\"matching_mode\":\"strict\",\"url\":\"https://vault.${var.dns_postfix}/v1/auth/oidc/oidc/callback\"}]}")
      create_or_get "core/applications" "slug" "vault" \
        "{\"name\":\"Vault\",\"slug\":\"vault\",\"provider\":$VAULT_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://vault.${var.dns_postfix}/ui/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/hashicorp-vault.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      %{if var.deploy_uptime_kuma}
      echo '[+] Uptime Kuma...'
      UKUMA_PK=$(create_or_get "providers/proxy" "name" "Uptime Kuma" \
        "{\"name\":\"Uptime Kuma\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"mode\":\"forward_single\",\"external_host\":\"https://status.${var.dns_postfix}\"}")
      create_or_get "core/applications" "slug" "uptime-kuma" \
        "{\"name\":\"Uptime Kuma\",\"slug\":\"uptime-kuma\",\"provider\":$UKUMA_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://status.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/uptime-kuma.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null
      PROXY_PKS="$PROXY_PKS,$UKUMA_PK"
      %{endif}

      %{if var.deploy_lam}
      echo '[+] LAM...'
      LAM_PK=$(create_or_get "providers/proxy" "name" "LDAP Account Manager" \
        "{\"name\":\"LDAP Account Manager\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"mode\":\"forward_single\",\"external_host\":\"https://lam.${var.dns_postfix}\"}")
      create_or_get "core/applications" "slug" "lam" \
        "{\"name\":\"LDAP Account Manager\",\"slug\":\"lam\",\"provider\":$LAM_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://lam.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/png/ldap-account-manager.png\",\"policy_engine_mode\":\"any\"}" > /dev/null
      PROXY_PKS="$PROXY_PKS,$LAM_PK"
      %{endif}

      %{if var.deploy_netbox}
      echo '[+] Netbox OIDC provider...'
      # Netbox uses native OIDC (not proxy) — create OAuth2 provider
      NETBOX_PK=$(create_or_get "providers/oauth2" "name" "Netbox OIDC" \
        "{\"name\":\"Netbox OIDC\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"client_type\":\"confidential\",\"client_id\":\"netbox\",\"signing_key\":\"$CERT_PK\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"https://netbox.${var.dns_postfix}/oauth/complete/oidc/\"}]}")
      create_or_get "core/applications" "slug" "netbox" \
        "{\"name\":\"Netbox\",\"slug\":\"netbox\",\"provider\":$NETBOX_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://netbox.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/netbox.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      # Store OIDC credentials in separate Vault path (not managed by Terraform).
      # Filter by the provider name we created on line 132 ("Netbox OIDC"),
      # not "Netbox" — the latter is the application name and would miss.
      NETBOX_OIDC_SECRET=$(curl -sk -H "Authorization: Bearer $TOKEN" \
        "$API/providers/oauth2/" | jq -r --arg name "Netbox OIDC" '[.results[] | select(.name == $name)][0].client_secret // empty')
      if [ -n "$NETBOX_OIDC_SECRET" ]; then
        curl -sk -X POST -H "X-Vault-Token: ${var.vault_token}" -H "Content-Type: application/json" \
          "${var.vault_address}/v1/secret/data/netbox-oidc" \
          -d "{\"data\":{\"oidc_client_id\":\"netbox\",\"oidc_client_secret\":\"$NETBOX_OIDC_SECRET\",\"oidc_endpoint\":\"https://auth.${var.dns_postfix}/application/o/netbox/\"}}" > /dev/null
        echo "    OIDC credentials stored at secret/netbox-oidc"
      else
        echo "    [!] Netbox OIDC client_secret not found — SSO will fail until secret/netbox-oidc is populated"
      fi
      %{endif}

      %{if var.deploy_unifi_dns}
      echo '[+] unifi-dns OIDC provider...'
      # unifi-dns uses native OIDC (authlib code flow) — create OAuth2 provider.
      # Callback path is /api/auth/callback (backend/app/auth.py).
      UNIFIDNS_PK=$(create_or_get "providers/oauth2" "name" "unifi-dns OIDC" \
        "{\"name\":\"unifi-dns OIDC\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"client_type\":\"confidential\",\"client_id\":\"unifi-dns\",\"signing_key\":\"$CERT_PK\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"https://unifi-dns.${var.dns_postfix}/api/auth/callback\"}]}")
      create_or_get "core/applications" "slug" "unifi-dns" \
        "{\"name\":\"UniFi DNS\",\"slug\":\"unifi-dns\",\"provider\":$UNIFIDNS_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://unifi-dns.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/unifi.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      # Store OIDC credentials in the placeholder Vault path (not managed by Terraform).
      # OIDC_ISSUER for the app = oidc_endpoint; authlib appends /.well-known/openid-configuration.
      UNIFIDNS_OIDC_SECRET=$(curl -sk -H "Authorization: Bearer $TOKEN" \
        "$API/providers/oauth2/" | jq -r --arg name "unifi-dns OIDC" '[.results[] | select(.name == $name)][0].client_secret // empty')
      if [ -n "$UNIFIDNS_OIDC_SECRET" ]; then
        curl -sk -X POST -H "X-Vault-Token: ${var.vault_token}" -H "Content-Type: application/json" \
          "${var.vault_address}/v1/secret/data/unifi-dns-oidc" \
          -d "{\"data\":{\"oidc_client_id\":\"unifi-dns\",\"oidc_client_secret\":\"$UNIFIDNS_OIDC_SECRET\",\"oidc_endpoint\":\"https://auth.${var.dns_postfix}/application/o/unifi-dns/\"}}" > /dev/null
        echo "    OIDC credentials stored at secret/unifi-dns-oidc"
      else
        echo "    [!] unifi-dns OIDC client_secret not found — SSO will fail until secret/unifi-dns-oidc is populated"
      fi
      %{endif}

      %{if var.deploy_forgejo}
      echo '[+] Forgejo OIDC provider...'
      # Forgejo uses native OIDC (OAuth2 "authentication source") — create an
      # OAuth2 provider. Forgejo's client callback path is
      # /user/oauth2/<AuthName>/callback; the auth source created post-deploy
      # (Phase 2b) is named "authentik", hence the redirect below.
      FORGEJO_PK=$(create_or_get "providers/oauth2" "name" "forgejo OIDC" \
        "{\"name\":\"forgejo OIDC\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"client_type\":\"confidential\",\"client_id\":\"forgejo\",\"signing_key\":\"$CERT_PK\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"https://git.${var.dns_postfix}/user/oauth2/authentik/callback\"}]}")
      create_or_get "core/applications" "slug" "forgejo" \
        "{\"name\":\"Forgejo\",\"slug\":\"forgejo\",\"provider\":$FORGEJO_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://git.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/forgejo.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      # Store OIDC credentials in the placeholder Vault path (not managed by
      # Terraform). Filter by the provider name created above ("forgejo OIDC").
      FORGEJO_OIDC_SECRET=$(curl -sk -H "Authorization: Bearer $TOKEN" \
        "$API/providers/oauth2/" | jq -r --arg name "forgejo OIDC" '[.results[] | select(.name == $name)][0].client_secret // empty')
      if [ -n "$FORGEJO_OIDC_SECRET" ]; then
        curl -sk -X POST -H "X-Vault-Token: ${var.vault_token}" -H "Content-Type: application/json" \
          "${var.vault_address}/v1/secret/data/forgejo-oidc" \
          -d "{\"data\":{\"oidc_client_id\":\"forgejo\",\"oidc_client_secret\":\"$FORGEJO_OIDC_SECRET\",\"oidc_endpoint\":\"https://auth.${var.dns_postfix}/application/o/forgejo/\"}}" > /dev/null
        echo "    OIDC credentials stored at secret/forgejo-oidc"
      else
        echo "    [!] Forgejo OIDC client_secret not found — SSO will fail until secret/forgejo-oidc is populated"
      fi
      %{endif}

      %{if var.deploy_kaneo}
      echo '[+] Kaneo OIDC provider...'
      # Kaneo uses a native custom-OIDC backend. Its callback path is fixed at
      # /api/auth/oauth2/callback/custom (the "custom" provider slug). Kaneo
      # links accounts by verified email only — there is NO group→role mapping,
      # so workspace/project membership is granted manually in the Kaneo UI.
      # Icon: homarr-labs/dashboard-icons has no kaneo icon, so we use the
      # selfh.st icon set via jsDelivr (Authentik accepts meta_icon as a URL).
      KANEO_ICON="https://cdn.jsdelivr.net/gh/selfhst/icons/svg/kaneo.svg"
      KANEO_PK=$(create_or_get "providers/oauth2" "name" "kaneo OIDC" \
        "{\"name\":\"kaneo OIDC\",\"authorization_flow\":\"$AUTHZ_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",\"client_type\":\"confidential\",\"client_id\":\"kaneo\",\"signing_key\":\"$CERT_PK\",\"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"https://tasks.${var.dns_postfix}/api/auth/oauth2/callback/custom\"}]}")
      create_or_get "core/applications" "slug" "kaneo" \
        "{\"name\":\"Kaneo\",\"slug\":\"kaneo\",\"provider\":$KANEO_PK,\"group\":\"Admin\",\"meta_launch_url\":\"https://tasks.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"$KANEO_ICON\",\"policy_engine_mode\":\"any\"}" > /dev/null
      # create_or_get only creates when absent, so ensure the icon is set on an
      # app that already exists (idempotent PATCH by slug).
      curl -sk -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        "$API/core/applications/kaneo/" -d "{\"meta_icon\":\"$KANEO_ICON\"}" > /dev/null

      # Store OIDC credentials in the placeholder Vault path (not managed by
      # Terraform). Filter by the provider name created above ("kaneo OIDC").
      KANEO_OIDC_SECRET=$(curl -sk -H "Authorization: Bearer $TOKEN" \
        "$API/providers/oauth2/" | jq -r --arg name "kaneo OIDC" '[.results[] | select(.name == $name)][0].client_secret // empty')
      if [ -n "$KANEO_OIDC_SECRET" ]; then
        curl -sk -X POST -H "X-Vault-Token: ${var.vault_token}" -H "Content-Type: application/json" \
          "${var.vault_address}/v1/secret/data/kaneo-oidc" \
          -d "{\"data\":{\"oidc_client_id\":\"kaneo\",\"oidc_client_secret\":\"$KANEO_OIDC_SECRET\",\"oidc_endpoint\":\"https://auth.${var.dns_postfix}/application/o/kaneo/\"}}" > /dev/null
        echo "    OIDC credentials stored at secret/kaneo-oidc"
      else
        echo "    [!] Kaneo OIDC client_secret not found — SSO will fail until secret/kaneo-oidc is populated"
      fi
      %{endif}

      # --- Documentation (launch URL only — no auth, public access) ---
      echo '[+] Documentation...'
      create_or_get "core/applications" "slug" "docs" \
        "{\"name\":\"Documentation\",\"slug\":\"docs\",\"group\":\"Lab\",\"meta_launch_url\":\"https://docs.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"https://raw.githubusercontent.com/squidfunk/mkdocs-material/master/material/templates/.icons/logo.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      # --- Kasm (launch URL only — authenticates directly via LDAP to Samba AD) ---
      echo '[+] Kasm Workspaces...'
      create_or_get "core/applications" "slug" "kasm" \
        "{\"name\":\"Kasm Workspaces\",\"slug\":\"kasm\",\"group\":\"Lab\",\"meta_launch_url\":\"https://kasm.${var.dns_postfix}/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/kasm-workspaces.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      # --- Microsoft 365 launcher tiles (no provider — auth is UTSA Entra, not
      #     authentik; these are just bookmarks on the user dashboard) ---
      echo '[+] Microsoft Teams...'
      create_or_get "core/applications" "slug" "teams" \
        "{\"name\":\"Microsoft Teams\",\"slug\":\"teams\",\"group\":\"M365\",\"meta_launch_url\":\"https://teams.microsoft.com/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/microsoft-teams.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      echo '[+] Outlook Web...'
      create_or_get "core/applications" "slug" "outlook" \
        "{\"name\":\"Outlook Web\",\"slug\":\"outlook\",\"group\":\"M365\",\"meta_launch_url\":\"https://outlook.office.com/mail/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/microsoft-outlook.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      echo '[+] Microsoft 365 portal...'
      create_or_get "core/applications" "slug" "m365" \
        "{\"name\":\"Microsoft 365\",\"slug\":\"m365\",\"group\":\"M365\",\"meta_launch_url\":\"https://www.microsoft365.com/\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/microsoft-365.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      # SharePoint: login-routed launcher (lands on the user's tenant SharePoint
      # home). For a direct tenant link, swap to https://<tenant>.sharepoint.com
      echo '[+] SharePoint...'
      create_or_get "core/applications" "slug" "sharepoint" \
        "{\"name\":\"SharePoint\",\"slug\":\"sharepoint\",\"group\":\"M365\",\"meta_launch_url\":\"https://www.microsoft365.com/launch/sharepoint\",\"open_in_new_tab\":true,\"meta_icon\":\"$ICON/svg/microsoft-sharepoint.svg\",\"policy_engine_mode\":\"any\"}" > /dev/null

      # --- Wire proxy providers into the embedded outpost ---
      echo '[+] Updating embedded outpost with proxy providers...'
      OUTPOST_PK=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/outposts/instances/" \
        | jq -r '[.results[] | select(.type == "proxy")][0].pk // empty')

      if [ -n "$OUTPOST_PK" ]; then
        # Build JSON array of provider PKs
        PROVIDER_ARRAY=$(echo "$PROXY_PKS" | tr ',' '\n' | grep -v '^$' | jq -R 'tonumber' | jq -s '.')
        curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
          -X PATCH "$API/outposts/instances/$OUTPOST_PK/" \
          -d "{\"providers\":$PROVIDER_ARRAY}" > /dev/null
        echo "    Embedded outpost updated with $(echo "$PROVIDER_ARRAY" | jq 'length') proxy providers"
      else
        echo "    [!] No embedded proxy outpost found — create one in Authentik Admin"
      fi

      # --- Create the "groups" OIDC scope mapping (codifies a live change) ---
      # Authentik ships no groups scope mapping by default. Forgejo's OIDC auth
      # source maps org/team membership from a "groups" claim, so we create a
      # scope property-mapping that emits the user's Authentik group names. This
      # was previously applied live via the API; creating it here (before the
      # assignment loop below) makes it reproducible AND means the loop attaches
      # it to every OAuth2 provider's property_mappings — forgejo included.
      echo '[+] Ensuring "groups" OIDC scope mapping exists...'
      GROUPS_MAPPING_PAYLOAD=$(jq -nc \
        --arg name "groups" \
        --arg scope "groups" \
        --arg desc "Lab: emit the user's Authentik group names as a 'groups' claim (Forgejo/OIDC team mapping)" \
        --arg expr 'return {"groups": [group.name for group in user.ak_groups.all()]}' \
        '{name:$name, scope_name:$scope, description:$desc, expression:$expr}')
      create_or_get "propertymappings/provider/scope" "name" "groups" "$GROUPS_MAPPING_PAYLOAD" > /dev/null

      # --- Assign scope mappings to all OAuth2 providers ---
      echo '[+] Assigning scope mappings to OAuth2 providers...'
      SCOPE_PKS=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/propertymappings/provider/scope/" | jq -c '[.results[].pk]')
      curl -sk -H "Authorization: Bearer $TOKEN" "$API/providers/oauth2/" | jq -r '.results[].pk' | while read pk; do
        curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
          -X PATCH "$API/providers/oauth2/$pk/" \
          -d "{\"property_mappings\":$SCOPE_PKS}" > /dev/null
      done
      echo "    Scope mappings assigned to all OAuth2 providers"

      %{if var.deploy_samba_ad}
      # --- Samba AD LDAP source (import AD users/groups into Authentik) ---
      # Codifies the hand-made source: LDAPS to dc01, base/bind DN derived from
      # the realm, the default LDAP + Active Directory property mappings, and
      # the lab root CA as the TLS verification cert so ldaps://dc01 validates
      # once the DC serves its Vault-PKI cert (see null_resource.samba_ldaps_cert).
      # create_or_get only creates; we always PATCH to converge an existing
      # (manually-created) source to this config. The bind password is NEVER
      # clobbered here — it is set ONLY if secret/samba-ad.authentik_sync_password
      # exists, so the live working bind is preserved when that field is absent.
      echo '[+] Reconciling Samba AD LDAP source...'

      # Lab root CA -> cert-keypair (for LDAPS peer verification). Idempotent.
      LAB_CA=$(curl -sk -H "X-Vault-Token: ${var.vault_token}" "${var.vault_address}/v1/pki/cert/ca" | jq -r '.data.certificate // empty')
      CA_PK=""
      if [ -n "$LAB_CA" ]; then
        CA_PK=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/crypto/certificatekeypairs/" | jq -r '[.results[] | select(.name == "Lab Root CA")][0].pk // empty')
        if [ -z "$CA_PK" ]; then
          CA_PK=$(curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "$API/crypto/certificatekeypairs/" -d "$(jq -nc --arg c "$LAB_CA" '{name:"Lab Root CA",certificate_data:$c}')" | jq -r '.pk // empty')
        fi
      fi

      # Default LDAP + Active Directory source property mappings (managed names).
      # AD set = the default-* and ms-* mappings (the openldap-* ones aren't part
      # of the AD preset). Assigned to the NEW fields user_property_mappings /
      # group_property_mappings (the base Source model renamed these; the old
      # property_mappings/_group are read-only aliases and a PATCH to them is
      # silently dropped).
      LDAP_MAPS=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/propertymappings/all/?page_size=200")
      LDAP_USER_PKS=$(echo "$LDAP_MAPS" | jq -c '[.results[] | select((.managed // "") | test("goauthentik.io/sources/ldap/(default-|ms-)")) | .pk]')
      LDAP_GROUP_PKS=$(echo "$LDAP_MAPS" | jq -c '[.results[] | select((.managed // "") == "goauthentik.io/sources/ldap/default-name") | .pk]')

      # Optional bind password (preserve the live one when absent in Vault).
      SYNC_PW=$(curl -sk -H "X-Vault-Token: ${var.vault_token}" "${var.vault_address}/v1/secret/data/samba-ad" | jq -r '.data.data.authentik_sync_password // empty')

      LDAP_PK=$(create_or_get "sources/ldap" "slug" "samba-ad" "$(jq -nc --arg uri "ldaps://dc01.${var.dns_postfix}" --arg bind "CN=authentik-sync,CN=Users,${local.ad_base_dn}" --arg base "${local.ad_base_dn}" '{name:"Samba AD",slug:"samba-ad",server_uri:$uri,bind_cn:$bind,base_dn:$base}')")

      LDAP_PATCH=$(jq -nc \
        --arg uri "ldaps://dc01.${var.dns_postfix}" \
        --arg bind "CN=authentik-sync,CN=Users,${local.ad_base_dn}" \
        --arg base "${local.ad_base_dn}" \
        --argjson um "$LDAP_USER_PKS" --argjson gm "$LDAP_GROUP_PKS" \
        '{enabled:true,server_uri:$uri,start_tls:false,bind_cn:$bind,base_dn:$base,sync_users:true,sync_groups:true,object_uniqueness_field:"objectSid",group_membership_field:"member",user_property_mappings:$um,group_property_mappings:$gm}')
      [ -n "$SYNC_PW" ] && LDAP_PATCH=$(echo "$LDAP_PATCH" | jq -c --arg p "$SYNC_PW" '. + {bind_password:$p}')
      [ -n "$CA_PK" ]   && LDAP_PATCH=$(echo "$LDAP_PATCH" | jq -c --arg c "$CA_PK" '. + {peer_certificate:$c}')
      # Authentik source detail/PATCH endpoints are keyed by SLUG (lookup_field
      # = slug), NOT pk — PATCHing by pk returns 404. create_or_get above still
      # returns the pk, which we only use to confirm the source exists.
      [ -n "$LDAP_PK" ] && curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X PATCH "$API/sources/ldap/samba-ad/" -d "$LDAP_PATCH" > /dev/null
      echo "    Samba AD source reconciled (user-maps=$(echo "$LDAP_USER_PKS" | jq 'length'), group-maps=$(echo "$LDAP_GROUP_PKS" | jq 'length'), ldaps://dc01.${var.dns_postfix})"
      %{endif}

      # --- Configure Vault OIDC auth backend ---
      echo '[+] Configuring Vault OIDC SSO...'
      VAULT_OIDC_SECRET=$(curl -sk -H "Authorization: Bearer $TOKEN" "$API/providers/oauth2/" | \
        jq -r '[.results[] | select(.client_id == "vault")][0].client_secret // empty')
      if [ -n "$VAULT_OIDC_SECRET" ]; then
        # Store secret in Vault KV
        curl -sk -X POST -H "X-Vault-Token: ${var.vault_token}" -H "Content-Type: application/json" \
          "${var.vault_address}/v1/secret/data/vault-oidc" \
          -d "{\"data\":{\"client_id\":\"vault\",\"client_secret\":\"$VAULT_OIDC_SECRET\",\"discovery_url\":\"https://auth.${var.dns_postfix}/application/o/vault/\"}}" > /dev/null

        # Enable OIDC auth backend (idempotent — ignores if already enabled)
        curl -sk -X POST -H "X-Vault-Token: ${var.vault_token}" \
          "${var.vault_address}/v1/sys/auth/oidc" \
          -d '{"type":"oidc","description":"Authentik SSO"}' > /dev/null 2>&1 || true

        # Get root CA for OIDC discovery — read directly from Vault's PKI
        # mount instead of the old gluster cert path (decommissioned in
        # Phase 3 of the storage migration).
        CA_PEM=$(curl -sk -H "X-Vault-Token: ${var.vault_token}" \
          "${var.vault_address}/v1/pki/cert/ca" \
          | jq -r '.data.certificate // ""')

        # Configure OIDC (uses jq to safely embed CA cert with newlines)
        OIDC_PAYLOAD=$(jq -n \
          --arg url "https://auth.${var.dns_postfix}/application/o/vault/" \
          --arg id "vault" \
          --arg secret "$VAULT_OIDC_SECRET" \
          --arg ca "$CA_PEM" \
          '{oidc_discovery_url: $url, oidc_client_id: $id, oidc_client_secret: $secret, default_role: "default", oidc_discovery_ca_pem: $ca}')
        curl -sk -X POST -H "X-Vault-Token: ${var.vault_token}" -H "Content-Type: application/json" \
          "${var.vault_address}/v1/auth/oidc/config" \
          -d "$OIDC_PAYLOAD" > /dev/null || true

        # Create default OIDC role
        OIDC_ROLE=$(jq -n \
          --arg dns "${var.dns_postfix}" \
          '{
            bound_audiences: ["vault"],
            allowed_redirect_uris: [
              ("https://vault." + $dns + "/ui/vault/auth/oidc/oidc/callback"),
              ("https://vault." + $dns + "/v1/auth/oidc/oidc/callback")
            ],
            user_claim: "preferred_username",
            token_policies: ["default", "oidc-admin"],
            token_ttl: "1h",
            token_max_ttl: "24h",
            oidc_scopes: ["openid", "profile", "email"]
          }')
        curl -sk -X POST -H "X-Vault-Token: ${var.vault_token}" -H "Content-Type: application/json" \
          "${var.vault_address}/v1/auth/oidc/role/default" \
          -d "$OIDC_ROLE" > /dev/null || true

        # Create oidc-admin policy
        curl -sk -X PUT -H "X-Vault-Token: ${var.vault_token}" -H "Content-Type: application/json" \
          "${var.vault_address}/v1/sys/policies/acl/oidc-admin" \
          -d '{"policy":"path \"*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\", \"sudo\"] }"}' > /dev/null || true

        echo "    Vault OIDC configured (auth backend + role + policy)"
      fi

      echo '[+] Authentik applications configured'
      EOT
    ]
  }
}
