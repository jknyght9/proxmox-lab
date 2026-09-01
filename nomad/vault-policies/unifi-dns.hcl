# Vault policy for the unifi-dns job
# Allows unifi-dns to read its secrets from Vault KV v2.

# App secrets (Postgres password, session key)
path "secret/data/unifi-dns" {
  capabilities = ["read"]
}

# OIDC credentials (written by authentik_apps, not Terraform)
path "secret/data/unifi-dns-oidc" {
  capabilities = ["read"]
}

# UniFi controller API key (shared with netbox inventory sync)
path "secret/data/unifi" {
  capabilities = ["read"]
}

# Metadata reads (optional, for debugging)
path "secret/metadata/unifi-dns" {
  capabilities = ["read", "list"]
}

path "secret/metadata/unifi-dns-oidc" {
  capabilities = ["read", "list"]
}

# Root CA cert so the Nomad template stanza can write it to
# /local/certs/root_ca.crt — the backend's REQUESTS_CA_BUNDLE / SSL_CERT_FILE
# point there for validating OIDC discovery against internal HTTPS (auth.<domain>).
path "pki/cert/ca" {
  capabilities = ["read"]
}
