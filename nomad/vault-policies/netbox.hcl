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
