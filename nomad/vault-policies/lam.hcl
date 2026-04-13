# Vault policy for LDAP Account Manager (LAM)
# Allows reading cluster config for AD connection details

path "secret/data/config/cluster" {
  capabilities = ["read"]
}

path "secret/data/config/nomad-nodes" {
  capabilities = ["read"]
}
