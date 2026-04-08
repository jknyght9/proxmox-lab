# Vault policy for Traefik job
# Allows Traefik to read the root CA certificate so LEGO can trust
# Vault's own ACME endpoint when requesting certs.

path "pki/cert/ca" {
  capabilities = ["read"]
}
