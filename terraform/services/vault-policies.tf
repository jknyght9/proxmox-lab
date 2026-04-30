# =============================================================================
# Vault Policies — read from nomad/vault-policies/*.hcl
# Replaces: curl-based policy creation in deploy scripts
# =============================================================================

resource "vault_policy" "nomad_server" {
  name   = "nomad-server"
  policy = file("${path.module}/../../nomad/vault-policies/nomad-server.hcl")
}

# oidc-admin policy is created via authentik_apps null_resource (not Terraform)
# because the OIDC auth backend setup depends on Authentik being running first.

resource "vault_policy" "authentik" {
  count  = var.deploy_authentik ? 1 : 0
  name   = "authentik"
  policy = file("${path.module}/../../nomad/vault-policies/authentik.hcl")
}

resource "vault_policy" "samba_ad" {
  count  = var.deploy_samba_ad ? 1 : 0
  name   = "samba-ad"
  policy = file("${path.module}/../../nomad/vault-policies/samba-ad.hcl")
}

resource "vault_policy" "backup" {
  count  = var.deploy_backup ? 1 : 0
  name   = "backup"
  policy = file("${path.module}/../../nomad/vault-policies/backup.hcl")
}

resource "vault_policy" "lam" {
  count  = var.deploy_lam ? 1 : 0
  name   = "lam"
  policy = file("${path.module}/../../nomad/vault-policies/lam.hcl")
}

resource "vault_policy" "tailscale" {
  count  = var.deploy_tailscale ? 1 : 0
  name   = "tailscale"
  policy = file("${path.module}/../../nomad/vault-policies/tailscale.hcl")
}

resource "vault_policy" "netbox" {
  count  = var.deploy_netbox ? 1 : 0
  name   = "netbox"
  policy = file("${path.module}/../../nomad/vault-policies/netbox.hcl")
}

resource "vault_policy" "netbox_sync" {
  count  = var.deploy_netbox && var.unifi_address != "" ? 1 : 0
  name   = "netbox-sync"
  policy = file("${path.module}/../../nomad/vault-policies/netbox-sync.hcl")
}

resource "vault_policy" "domain_join" {
  count  = var.deploy_samba_ad ? 1 : 0
  name   = "domain-join"
  policy = file("${path.module}/../../nomad/vault-policies/domain-join.hcl")
}
