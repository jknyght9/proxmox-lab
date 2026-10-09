# =============================================================================
# Forgejo OIDC authentication source (codifies the former manual "Phase 2b")
#
# Authentik creates the Forgejo OAuth2 provider + application and writes the
# client secret to secret/forgejo-oidc (authentik-apps.tf). This resource then
# configures the Forgejo-SIDE auth source via the forgejo CLI so SSO works out
# of the box, including role mapping:
#   - --group-claim-name groups  : read the user's groups from the "groups" claim
#                                   (Authentik's groups scope mapping emits it)
#   - --admin-group <admin group>: members of this group become Forgejo admins;
#                                   everyone else is a normal user.
# The source is named "authentik" to match the redirect URI Authentik registers
# (https://git.<postfix>/user/oauth2/authentik/callback).
#
# Idempotent: looks up an existing "authentik" source and update-oauth's it,
# else add-oauth. Tolerant (exit 0 on CLI failure, like forgejo_runner_token) so
# a transient Forgejo/CA-trust hiccup doesn't fail the whole services apply —
# the warning is printed and the next apply retries.
#
# NOTE: Forgejo's --admin-group takes a SINGLE group value, so only the first
# entry of var.sso_admin_groups maps to Forgejo admin. Forgejo must trust the
# lab root CA to fetch the OIDC discovery document from auth.<postfix>.
# =============================================================================

locals {
  forgejo_admin_group = length(var.sso_admin_groups) > 0 ? var.sso_admin_groups[0] : "Lab-Admins"
}

resource "null_resource" "forgejo_oidc_source" {
  count = var.deploy_forgejo && var.configure_authentik ? 1 : 0

  depends_on = [
    nomad_job.forgejo,
    null_resource.authentik_apps,
  ]

  triggers = {
    dns_postfix = var.dns_postfix
    admin_group = local.forgejo_admin_group
    # re-run on any change to the reconcile logic below
    rev = "1"
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
      VAULT_ADDR="${var.vault_address}"
      VAULT_TOKEN="${var.vault_token}"
      ADMIN_GROUP="${local.forgejo_admin_group}"

      echo '[+] Reading Forgejo OIDC secret from Vault...'
      OIDC=$(curl -sk -m5 -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/secret/data/forgejo-oidc")
      CID=$(echo "$OIDC" | jq -r '.data.data.oidc_client_id // empty')
      CSECRET=$(echo "$OIDC" | jq -r '.data.data.oidc_client_secret // empty')
      ENDPOINT=$(echo "$OIDC" | jq -r '.data.data.oidc_endpoint // empty')
      if [ -z "$CID" ] || [ -z "$CSECRET" ] || [ -z "$ENDPOINT" ]; then
        echo '[!] secret/forgejo-oidc incomplete — run authentik_apps first. Skipping.'
        exit 0
      fi
      DISCOVERY="$${ENDPOINT%/}/.well-known/openid-configuration"

      # forgejo CLI via the running alloc (node-agnostic — no docker/container lookup).
      fj() { nomad alloc exec -task forgejo -job forgejo su-exec git forgejo "$@"; }

      echo '[+] Looking up existing "authentik" auth source...'
      SRC_ID=$(fj admin auth list 2>/dev/null | awk '$2=="authentik"{print $1; exit}')

      if [ -n "$SRC_ID" ]; then
        echo "    updating auth source $SRC_ID (admin-group=$ADMIN_GROUP)"
        fj admin auth update-oauth --id "$SRC_ID" \
          --name authentik --provider openidConnect \
          --key "$CID" --secret "$CSECRET" --auto-discover-url "$DISCOVERY" \
          --scopes openid --scopes profile --scopes email --scopes groups \
          --group-claim-name groups --admin-group "$ADMIN_GROUP" \
          || { echo "[!] forgejo update-oauth failed — leaving source unchanged"; exit 0; }
      else
        echo "    creating auth source (admin-group=$ADMIN_GROUP)"
        fj admin auth add-oauth \
          --name authentik --provider openidConnect \
          --key "$CID" --secret "$CSECRET" --auto-discover-url "$DISCOVERY" \
          --scopes openid --scopes profile --scopes email --scopes groups \
          --group-claim-name groups --admin-group "$ADMIN_GROUP" \
          || { echo "[!] forgejo add-oauth failed — will retry next apply"; exit 0; }
      fi
      echo '[+] Forgejo OIDC auth source reconciled.'
      EOT
    ]
  }
}
