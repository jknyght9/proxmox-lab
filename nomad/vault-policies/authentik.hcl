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

# Allow reading the root CA cert so the Nomad template stanza can write
# it to /local/certs/root_ca.crt — Authentik's REQUESTS_CA_BUNDLE points
# there for validating outbound HTTPS to other internal services
# (Samba LDAPS, Vault, etc.). Replaces the gluster-mounted /certs path.
path "pki/cert/ca" {
  capabilities = ["read"]
}
