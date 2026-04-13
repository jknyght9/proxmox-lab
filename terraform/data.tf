# =============================================================================
# Vault Data Sources (KV v2)
# =============================================================================
#
# Secrets stored in Vault KV v2 at secret/services/* and secret/config/*.
# Written by syncSecretsToVault() in lib/credentials.sh during Vault setup.
#
# Conditional on vault_address being set — during initial bootstrap
# (before Vault exists), count = 0 and no API calls are made.

locals {
  vault_configured = var.vault_address != ""
}

data "vault_kv_secret_v2" "pihole" {
  count = local.vault_configured ? 1 : 0
  mount = "secret"
  name  = "services/pihole"
}

data "vault_kv_secret_v2" "cluster_config" {
  count = local.vault_configured ? 1 : 0
  mount = "secret"
  name  = "config/cluster"
}

data "vault_kv_secret_v2" "nomad_nodes" {
  count = local.vault_configured ? 1 : 0
  mount = "secret"
  name  = "config/nomad-nodes"
}
