# Vault policy for the periodic profile-folder reconciler.
# Reads the TrueNAS API keys for every NAS opted-in to roaming profiles
# plus the domain-join service-account password (used for LDAPS bind to
# Samba AD) and cluster config (for AD realm / base DN).

path "secret/data/nas/*" {
  capabilities = ["read"]
}

path "secret/data/samba-ad/service-accounts" {
  capabilities = ["read"]
}

path "secret/data/config/cluster" {
  capabilities = ["read"]
}

path "secret/data/config/nomad-nodes" {
  capabilities = ["read"]
}
