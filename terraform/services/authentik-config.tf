# =============================================================================
# Authentik Configuration — AD Sync via goauthentik/authentik provider
# =============================================================================

# The provider uses the bootstrap API token created during Authentik deploy.
# Requires: Authentik running + Samba AD running + authentik-sync account created.

data "vault_kv_secret_v2" "authentik_token" {
  count = var.deploy_authentik && var.deploy_samba_ad ? 1 : 0
  mount = vault_mount.secret.path
  name  = "authentik"
}

resource "authentik_source_ldap" "samba_ad" {
  count = var.deploy_authentik && var.deploy_samba_ad ? 1 : 0
  depends_on = [
    null_resource.ad_service_accounts,
    nomad_job.authentik,
  ]

  name = "Samba AD"
  slug = "samba-ad"

  server_uri     = "ldap://${local.nomad01_ip}"
  bind_cn        = "CN=authentik-sync,CN=Users,${local.ad_base_dn}"
  bind_password  = random_password.authentik_sync[0].result
  base_dn        = local.ad_base_dn
  start_tls      = false

  # Sync configuration
  sync_users          = true
  sync_groups         = true
  sync_users_password = true

  # AD-specific filters (exclude computer accounts)
  user_object_filter  = "(&(objectClass=user)(!(objectClass=computer)))"
  group_object_filter = "(objectClass=group)"

  # AD uses objectSid for uniqueness, member for group membership
  object_uniqueness_field  = "objectSid"
  group_membership_field   = "member"

  enabled = true
}
