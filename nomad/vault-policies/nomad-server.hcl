# Vault policy for Nomad server integration
# This policy allows Nomad servers to create tokens for jobs

# Allow creating tokens against the "nomad-cluster" role
path "auth/token/create/nomad-cluster" {
  capabilities = ["update"]
}

# Allow looking up the "nomad-cluster" role
path "auth/token/roles/nomad-cluster" {
  capabilities = ["read"]
}

# Allow looking up own token capabilities
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# Allow looking up incoming tokens for validation
path "auth/token/lookup" {
  capabilities = ["update"]
}

# Allow revoking tokens via accessor when jobs end
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}

# Allow renewing own token
path "auth/token/renew-self" {
  capabilities = ["update"]
}
