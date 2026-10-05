# Vault policy for Kaneo job
# This policy allows Kaneo to read its secrets from Vault KV v2

# Allow reading Kaneo secrets (postgres password + auth secret)
path "secret/data/kaneo" {
  capabilities = ["read"]
}

# Allow reading OIDC credentials (written by authentik_apps, not Terraform)
path "secret/data/kaneo-oidc" {
  capabilities = ["read"]
}

# Allow listing and reading metadata (optional, for debugging)
path "secret/metadata/kaneo" {
  capabilities = ["read", "list"]
}

path "secret/metadata/kaneo-oidc" {
  capabilities = ["read", "list"]
}

# Allow reading the root CA cert so the Nomad template stanza can write it to
# /local/certs/root_ca.crt — Kaneo's NODE_EXTRA_CA_CERTS points there for
# validating OIDC discovery against the internal HTTPS auth endpoint.
path "pki/cert/ca" {
  capabilities = ["read"]
}
