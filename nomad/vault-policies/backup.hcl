# Vault policy for backup job
# This policy allows the backup job to read its credentials from Vault KV v2

# Allow reading backup credentials (NFS/SMB server details)
path "secret/data/backup" {
  capabilities = ["read"]
}

# Allow listing and reading metadata (optional, for debugging)
path "secret/metadata/backup" {
  capabilities = ["read", "list"]
}
