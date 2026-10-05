# Vault policy for Forgejo job
# This policy allows Forgejo to read its secrets from Vault KV v2

# Allow reading Forgejo secrets (postgres + admin passwords)
path "secret/data/forgejo" {
  capabilities = ["read"]
}

# Allow reading OIDC credentials (written by authentik_apps, not Terraform)
path "secret/data/forgejo-oidc" {
  capabilities = ["read"]
}

# Allow listing and reading metadata (optional, for debugging)
path "secret/metadata/forgejo" {
  capabilities = ["read", "list"]
}

path "secret/metadata/forgejo-oidc" {
  capabilities = ["read", "list"]
}

# Allow reading the root CA cert so the Nomad template stanza can write it
# to /local/certs/root_ca.crt — Forgejo's SSL_CERT_FILE / GIT_SSL_CAINFO
# point there for validating OIDC discovery against internal HTTPS endpoints.
path "pki/cert/ca" {
  capabilities = ["read"]
}
