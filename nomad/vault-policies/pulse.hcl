# Vault policy for the pulse job
# Allows Pulse to read its secret (read-only PVE token + web-login password).

path "secret/data/pulse" {
  capabilities = ["read"]
}

path "secret/metadata/pulse" {
  capabilities = ["read", "list"]
}

# OIDC client credentials (Authentik). Populated by authentik-apps.tf after the
# Authentik provider/app for Pulse is created; consumed by the job's OIDC_* env.
path "secret/data/pulse-oidc" {
  capabilities = ["read"]
}

path "secret/metadata/pulse-oidc" {
  capabilities = ["read", "list"]
}

# Root CA cert so the Nomad template stanza can write it to
# /local/certs/root_ca.crt — Pulse (Go) points SSL_CERT_FILE there to validate
# the OIDC issuer's HTTPS (auth.<domain>, served with the internal PKI cert).
path "pki/cert/ca" {
  capabilities = ["read"]
}
