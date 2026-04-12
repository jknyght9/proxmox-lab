# =============================================================================
# Vault Data Sources
# =============================================================================
#
# Secrets are stored in Vault KV v2 at secret/services/* and secret/config/*.
# Written by syncSecretsToVault() in lib/credentials.sh during Vault setup.
#
# KV v2 note: the API path includes /data/ but the logical path does not.
# vault_generic_secret requires the full API path.

data "vault_generic_secret" "pihole" {
  path = "secret/data/services/pihole"
}

data "vault_generic_secret" "cluster_config" {
  path = "secret/data/config/cluster"
}

data "vault_generic_secret" "nomad_nodes" {
  path = "secret/data/config/nomad-nodes"
}
