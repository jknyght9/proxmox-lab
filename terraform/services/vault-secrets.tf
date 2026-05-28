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
  length           = 20
  special          = true
  override_special = "!@#%^&*" # Avoid shell-unsafe chars: ()=<>?:;'"
  keepers          = { service = "kasm" }
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

# prevent_destroy on every password backing a stateful service:
# regenerating these orphans the on-disk Postgres/Samba data that was
# initialized with the old value. If a user genuinely wants to tear a
# service down, they have to `terraform state rm` first — turning a
# silent destruction into an explicit one. (See incident 2026-05-01.)

resource "random_password" "authentik_secret_key" {
  count   = var.deploy_authentik ? 1 : 0
  length  = 50
  special = false
  keepers = { service = "authentik" }
  lifecycle { prevent_destroy = true }
}

resource "random_password" "authentik_admin" {
  count            = var.deploy_authentik ? 1 : 0
  length           = 20
  special          = true
  override_special = "!@#%^&*"
  keepers          = { service = "authentik" }
  lifecycle { prevent_destroy = true }
}

resource "random_password" "authentik_api_token" {
  count   = var.deploy_authentik ? 1 : 0
  length  = 40
  special = false
  keepers = { service = "authentik" }
  lifecycle { prevent_destroy = true }
}

resource "random_password" "authentik_postgres" {
  count   = var.deploy_authentik ? 1 : 0
  length  = 24
  special = false
  keepers = { service = "authentik" }
  lifecycle { prevent_destroy = true }
}

resource "random_password" "samba_admin" {
  count   = var.deploy_samba_ad ? 1 : 0
  length  = 24
  special = true
  keepers = { service = "samba-ad" }
  lifecycle { prevent_destroy = true }
}

resource "random_password" "netbox_secret_key" {
  count   = var.deploy_netbox ? 1 : 0
  length  = 50
  special = false
  keepers = { service = "netbox" }
  lifecycle { prevent_destroy = true }
}

resource "random_password" "netbox_postgres" {
  count   = var.deploy_netbox ? 1 : 0
  length  = 24
  special = false
  keepers = { service = "netbox" }
  lifecycle { prevent_destroy = true }
}

resource "random_password" "netbox_admin" {
  count            = var.deploy_netbox ? 1 : 0
  length           = 20
  special          = true
  override_special = "!@#%^&*"
  keepers          = { service = "netbox" }
  lifecycle { prevent_destroy = true }
}

resource "random_password" "netbox_api_token" {
  count   = var.deploy_netbox ? 1 : 0
  length  = 40
  special = false
  keepers = { service = "netbox" }
  lifecycle { prevent_destroy = true }
}

# --- Write Secrets to Vault KV ---

resource "vault_kv_secret_v2" "pihole" {
  mount = vault_mount.secret.path
  name  = "pihole"
  data_json = jsonencode({
    admin_password = random_password.pihole_admin.result
    root_password  = random_password.pihole_root.result
  })
}

resource "vault_kv_secret_v2" "kasm" {
  mount = vault_mount.secret.path
  name  = "kasm"
  data_json = jsonencode({
    admin_password = random_password.kasm_admin.result
  })
}

resource "vault_kv_secret_v2" "packer" {
  mount = vault_mount.secret.path
  name  = "packer"
  data_json = jsonencode({
    root_password     = random_password.packer_root.result
    ssh_password      = random_password.packer_ssh.result
    template_password = random_password.template_pass.result
  })
}

resource "vault_kv_secret_v2" "ssh_keys" {
  mount = vault_mount.secret.path
  name  = "ssh-keys"
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
    secret_key        = random_password.authentik_secret_key[0].result
    postgres_password = random_password.authentik_postgres[0].result
    admin_password    = random_password.authentik_admin[0].result
    admin_email       = "admin@${var.dns_postfix}"
    api_token         = random_password.authentik_api_token[0].result
  })
}

resource "vault_kv_secret_v2" "netbox" {
  count = var.deploy_netbox ? 1 : 0
  mount = vault_mount.secret.path
  name  = "netbox"
  data_json = jsonencode({
    secret_key        = random_password.netbox_secret_key[0].result
    postgres_password = random_password.netbox_postgres[0].result
    admin_password    = random_password.netbox_admin[0].result
    admin_email       = "admin@${var.dns_postfix}"
    api_token         = random_password.netbox_api_token[0].result
  })
}

# Placeholder for Netbox OIDC — populated by authentik_apps after Authentik is running.
# Must exist before Netbox starts so the Vault template doesn't block.
resource "vault_kv_secret_v2" "netbox_oidc" {
  count = var.deploy_netbox ? 1 : 0
  mount = vault_mount.secret.path
  name  = "netbox-oidc"
  data_json = jsonencode({
    oidc_client_id     = ""
    oidc_client_secret = ""
    oidc_endpoint      = ""
  })
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_kv_secret_v2" "unifi" {
  count = var.unifi_address != "" ? 1 : 0
  mount = vault_mount.secret.path
  name  = "unifi"
  data_json = jsonencode({
    address = var.unifi_address
    api_key = var.unifi_api_key
    site    = var.unifi_site
  })
}

# Removed: vault_kv_secret_v2.backup. The explicit backup job was retired
# in Phase 2/3; ZFS snapshots on the cluster_state NAS handle the backup
# role now. See plans/serene-brewing-cray.md.

# Tailscale auth key. The tailscale system job reads this at runtime via
# WIF and joins the tailnet on every Nomad node, advertising the lab
# subnet so remote clients can reach lab IPs over the tailnet.
resource "vault_kv_secret_v2" "tailscale" {
  count = var.deploy_tailscale ? 1 : 0
  mount = vault_mount.secret.path
  name  = "tailscale"
  data_json = jsonencode({
    auth_key = var.tailscale_auth_key
  })
}

resource "vault_kv_secret_v2" "samba_ad" {
  count = var.deploy_samba_ad ? 1 : 0
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
    dns_postfix    = var.dns_postfix
    dns_server     = var.dns_server_ip
    network_cidr   = var.network_cidr
    gateway        = var.network_gateway
    ad_realm       = var.ad_realm
    ad_domain      = var.ad_domain
    ad_realm_lower = local.ad_realm_lower
    base_dn        = local.ad_base_dn
    dns_forwarder  = var.dns_server_ip != "" ? var.dns_server_ip : var.network_gateway
  })
}

resource "vault_kv_secret_v2" "nomad_nodes" {
  mount = vault_mount.secret.path
  name  = "config/nomad-nodes"
  data_json = jsonencode({
    for name, ip in var.nomad_node_ips : "${name}_ip" => ip
  })
}
