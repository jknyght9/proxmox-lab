# =============================================================================
# Vault KV Secrets — generated passwords + cluster config
# Replaces: credentials.sh (generateServicePasswords + syncSecretsToVault)
# =============================================================================

# --- KV v2 Secrets Engine ---

resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv-v2"
  description = "Service secrets and configuration"
}

# --- Random Passwords (stable via keepers) ---

resource "random_password" "pihole_admin" {
  length  = 20
  special = true
  keepers = { service = "pihole" }
}

resource "random_password" "pihole_root" {
  length  = 20
  special = true
  keepers = { service = "pihole" }
}

resource "random_password" "kasm_admin" {
  length  = 20
  special = true
  keepers = { service = "kasm" }
}

resource "random_password" "packer_root" {
  length  = 16
  special = true
  keepers = { service = "packer" }
}

resource "random_password" "packer_ssh" {
  length  = 16
  special = true
  keepers = { service = "packer" }
}

resource "random_password" "template_pass" {
  length  = 16
  special = true
  keepers = { service = "packer" }
}

resource "random_password" "authentik_secret_key" {
  count   = var.deploy_authentik ? 1 : 0
  length  = 50
  special = false
  keepers = { service = "authentik" }
}

resource "random_password" "authentik_postgres" {
  count   = var.deploy_authentik ? 1 : 0
  length  = 24
  special = false
  keepers = { service = "authentik" }
}

resource "random_password" "samba_admin" {
  count   = var.deploy_samba_dc ? 1 : 0
  length  = 24
  special = true
  keepers = { service = "samba-ad" }
}

# --- Write Secrets to Vault KV ---

resource "vault_kv_secret_v2" "pihole" {
  mount = vault_mount.secret.path
  name  = "services/pihole"
  data_json = jsonencode({
    admin_password = random_password.pihole_admin.result
    root_password  = random_password.pihole_root.result
  })
}

resource "vault_kv_secret_v2" "kasm" {
  mount = vault_mount.secret.path
  name  = "services/kasm"
  data_json = jsonencode({
    admin_password = random_password.kasm_admin.result
  })
}

resource "vault_kv_secret_v2" "packer" {
  mount = vault_mount.secret.path
  name  = "services/packer"
  data_json = jsonencode({
    root_password     = random_password.packer_root.result
    ssh_password      = random_password.packer_ssh.result
    template_password = random_password.template_pass.result
  })
}

resource "vault_kv_secret_v2" "ssh_keys" {
  mount = vault_mount.secret.path
  name  = "services/ssh-keys"
  data_json = jsonencode({
    labadmin       = file(var.ssh_admin_private_key_file)
    labadmin_pub   = file(var.ssh_admin_public_key_file)
    enterprise     = file(var.ssh_enterprise_private_key_file)
    enterprise_pub = file("${var.ssh_enterprise_private_key_file}.pub")
  })
}

resource "vault_kv_secret_v2" "authentik" {
  count = var.deploy_authentik ? 1 : 0
  mount = vault_mount.secret.path
  name  = "authentik"
  data_json = jsonencode({
    AUTHENTIK_SECRET_KEY = random_password.authentik_secret_key[0].result
    POSTGRES_PASSWORD    = random_password.authentik_postgres[0].result
  })
}

resource "vault_kv_secret_v2" "samba_ad" {
  count = var.deploy_samba_dc ? 1 : 0
  mount = vault_mount.secret.path
  name  = "samba-ad"
  data_json = jsonencode({
    admin_password = random_password.samba_admin[0].result
  })
}

# --- Cluster Configuration ---

locals {
  ad_realm_lower = var.ad_realm != "" ? lower(var.ad_realm) : ""
  ad_base_dn     = var.ad_realm != "" ? join(",", [for part in split(".", local.ad_realm_lower) : "DC=${part}"]) : ""
}

resource "vault_kv_secret_v2" "cluster_config" {
  mount = vault_mount.secret.path
  name  = "config/cluster"
  data_json = jsonencode({
    dns_postfix   = var.dns_postfix
    dns_server    = var.dns_server_ip
    network_cidr  = var.network_cidr
    gateway       = var.network_gateway
    ad_realm      = var.ad_realm
    ad_domain     = var.ad_domain
    ad_realm_lower = local.ad_realm_lower
    base_dn       = local.ad_base_dn
    dns_forwarder = var.dns_server_ip != "" ? var.dns_server_ip : var.network_gateway
  })
}

resource "vault_kv_secret_v2" "nomad_nodes" {
  mount = vault_mount.secret.path
  name  = "config/nomad-nodes"
  data_json = jsonencode({
    for name, ip in var.nomad_node_ips : "${name}_ip" => ip
  })
}
