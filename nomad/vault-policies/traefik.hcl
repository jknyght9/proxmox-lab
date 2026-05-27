# Vault policy for the Traefik Nomad job.
#
# Allows Traefik to mint its own wildcard TLS cert from Vault PKI at
# startup (and renew it before expiry) via a Nomad template stanza, so
# there's no shared filesystem requirement for cert files.

path "pki_int/issue/acme-certs" {
  capabilities = ["update"]
}

# Optional: read CA chain if Traefik ever needs to validate upstreams
# against our internal PKI. Today it doesn't, but cheap to allow.
path "pki_int/cert/ca" {
  capabilities = ["read"]
}
path "pki_int/cert/ca_chain" {
  capabilities = ["read"]
}
