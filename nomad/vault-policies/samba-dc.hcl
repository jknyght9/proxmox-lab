# Vault policy for Samba AD Domain Controller jobs
# This policy allows Samba DCs to:
#   - Read AD secrets (admin password, sync credentials) from KV
#   - Issue TLS certificates from PKI for LDAPS

# Allow reading Samba AD secrets (admin password, sync credentials)
path "secret/data/samba-ad" {
  capabilities = ["read"]
}

# Allow listing and reading metadata (for debugging)
path "secret/metadata/samba-ad" {
  capabilities = ["read", "list"]
}

# Allow issuing TLS certificates for LDAPS from the intermediate CA
path "pki_int/issue/acme-certs" {
  capabilities = ["create", "update"]
}

# Allow reading the CA chain (for trust configuration)
path "pki/cert/ca" {
  capabilities = ["read"]
}

path "pki_int/cert/ca" {
  capabilities = ["read"]
}
