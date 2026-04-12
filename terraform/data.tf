# =============================================================================
# Vault Data Sources
# =============================================================================
#
# Secrets are stored in Vault KV v2 at secret/services/* and secret/config/*.
# Written by syncSecretsToVault() in lib/credentials.sh during Vault setup.
#
# These data sources are conditional on vault_address being set — during
# initial bootstrap (before Vault exists), they have count = 0 and make
# no API calls.
#
# KV v2 note: the API path includes /data/ but the logical path does not.

locals {
  vault_configured = var.vault_address != ""
}

data "vault_generic_secret" "pihole" {
  count = local.vault_configured ? 1 : 0
  path  = "secret/data/services/pihole"
}

data "vault_generic_secret" "cluster_config" {
  count = local.vault_configured ? 1 : 0
  path  = "secret/data/config/cluster"
}

data "vault_generic_secret" "nomad_nodes" {
  count = local.vault_configured ? 1 : 0
  path  = "secret/data/config/nomad-nodes"
}
