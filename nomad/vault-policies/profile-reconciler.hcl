# Vault policy for the periodic profile-folder reconciler.
# Reads the TrueNAS API keys for every NAS opted-in to roaming profiles
# plus the domain-join service-account password (used for LDAPS bind to
# Samba AD) and cluster config (for AD realm / base DN).

path "secret/data/infra/nas/*" {
  capabilities = ["read"]
}

path "secret/data/ad/service-accounts" {
  capabilities = ["read"]
}

path "secret/data/infra/config/cluster" {
  capabilities = ["read"]
}

path "secret/data/infra/config/nomad-nodes" {
  capabilities = ["read"]
}
