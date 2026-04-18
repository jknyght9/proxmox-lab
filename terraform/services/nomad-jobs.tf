# =============================================================================
# Nomad Jobs — deployed via Terraform nomad provider
# Replaces: all deployNomadJob SCP+SSH calls in lib/deploy/nomadJob/*.sh
# =============================================================================

resource "nomad_job" "traefik" {
  count      = var.deploy_traefik ? 1 : 0
  depends_on = [
    null_resource.service_directories,
    null_resource.install_traefik_cert,
    null_resource.traefik_tls_config,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/traefik.nomad.hcl.tpl", {
    dns_server = var.dns_server_ip
  })
  detach = false
}

resource "nomad_job" "authentik" {
  count      = var.deploy_authentik ? 1 : 0
  depends_on = [
    null_resource.service_directories,
    vault_policy.authentik,
    vault_jwt_auth_backend_role.authentik,
    vault_kv_secret_v2.authentik,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/authentik.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false
}

resource "nomad_job" "samba_dc" {
  count      = var.deploy_samba_dc ? 1 : 0
  depends_on = [
    null_resource.samba_directories,
    vault_policy.samba_dc,
    vault_jwt_auth_backend_role.samba_dc,
    vault_kv_secret_v2.samba_ad,
    vault_kv_secret_v2.cluster_config,
    vault_kv_secret_v2.nomad_nodes,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/samba-dc.nomad.hcl.tpl", {
    ad_realm = var.ad_realm
  })
  detach = false
}

resource "nomad_job" "uptime_kuma" {
  count      = var.deploy_uptime_kuma ? 1 : 0
  depends_on = [
    null_resource.service_directories,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/uptime-kuma.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false
}

resource "nomad_job" "lam" {
  count      = var.deploy_lam ? 1 : 0
  depends_on = [
    vault_policy.lam,
    vault_jwt_auth_backend_role.lam,
    vault_kv_secret_v2.cluster_config,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/lam.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false
}

resource "nomad_job" "backup" {
  count      = var.deploy_backup ? 1 : 0
  depends_on = [
    vault_policy.backup,
    vault_jwt_auth_backend_role.backup,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/backup.nomad.hcl.tpl", {
    backup_cron           = var.backup_cron
    backup_timezone       = var.backup_timezone
    backup_retention_days = var.backup_retention_days
  })
  detach = false
}

resource "nomad_job" "tailscale" {
  count      = var.deploy_tailscale ? 1 : 0
  depends_on = [
    vault_policy.tailscale,
    vault_jwt_auth_backend_role.tailscale,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/tailscale.nomad.hcl.tpl", {
    tailscale_subnet = var.network_cidr
  })
  detach = false
}
