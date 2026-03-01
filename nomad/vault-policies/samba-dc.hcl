# Vault policy for Samba AD Domain Controller jobs
# This policy allows Samba DCs to read AD secrets from Vault KV v2

# Allow reading Samba AD secrets (admin password, sync credentials)
path "secret/data/samba-ad" {
  capabilities = ["read"]
}

# Allow listing and reading metadata (for debugging)
path "secret/metadata/samba-ad" {
  capabilities = ["read", "list"]
}
