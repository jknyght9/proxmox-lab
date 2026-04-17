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

# Allow reading cluster config (AD realm, domain, DNS forwarder)
path "secret/data/config/cluster" {
  capabilities = ["read"]
}

# Allow reading Nomad node IPs (for DC host IP and DC-to-DC communication)
path "secret/data/config/nomad-nodes" {
  capabilities = ["read"]
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
