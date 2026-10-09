# =============================================================================
# Vault Data Sources (KV v2)
# =============================================================================
#
# Secrets stored in Vault KV v2 at secret/* and secret/config/*.
# Written by syncSecretsToVault() in lib/credentials.sh during Vault setup.
#
# Conditional on vault_address being set — during initial bootstrap
# (before Vault exists), count = 0 and no API calls are made.

locals {
  vault_configured = var.vault_address != ""
  nomad_configured = var.nomad_address != ""
}

data "vault_kv_secret_v2" "pihole" {
  count = local.vault_configured ? 1 : 0
  mount = "secret"
  name  = "pihole"
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

data "vault_kv_secret_v2" "kasm" {
  count = local.vault_configured ? 1 : 0
  mount = "secret"
  name  = "kasm"
}

# Build-runner VM: the instance-level runner registration token (minted by the
# services layer into secret/forgejo-runner) and the internal root CA, so the
# VM's Docker daemon, runner and job containers trust git.<postfix>.
data "vault_kv_secret_v2" "forgejo_runner" {
  count = local.vault_configured && var.deploy_builder ? 1 : 0
  mount = "secret"
  name  = "forgejo-runner"
}

data "vault_generic_secret" "pki_root_ca" {
  count = local.vault_configured && var.deploy_builder ? 1 : 0
  path  = "pki/cert/ca"
}
