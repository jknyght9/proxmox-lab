# Vault policy for Authentik job
# This policy allows Authentik to read its secrets from Vault KV v2

# Allow reading Authentik secrets
path "secret/data/authentik" {
  capabilities = ["read"]
}

# Allow listing and reading metadata (optional, for debugging)
path "secret/metadata/authentik" {
  capabilities = ["read", "list"]
}
