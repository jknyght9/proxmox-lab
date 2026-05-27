# Vault policy for Netbox job
# This policy allows Netbox to read its secrets from Vault KV v2

# Allow reading Netbox secrets
path "secret/data/netbox" {
  capabilities = ["read"]
}

# Allow reading OIDC credentials (written by authentik_apps, not Terraform)
path "secret/data/netbox-oidc" {
  capabilities = ["read"]
}

# Allow listing and reading metadata (optional, for debugging)
path "secret/metadata/netbox" {
  capabilities = ["read", "list"]
}

path "secret/metadata/netbox-oidc" {
  capabilities = ["read", "list"]
}

# Allow reading the root CA cert so the Nomad template stanza can write
# it to /local/certs/root_ca.crt — Netbox's REQUESTS_CA_BUNDLE points
# there for validating OIDC discovery against internal HTTPS endpoints.
# Replaces the gluster-mounted /certs path.
path "pki/cert/ca" {
  capabilities = ["read"]
}
