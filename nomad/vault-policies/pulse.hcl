# Vault policy for the pulse job
# Allows Pulse to read its secret (read-only PVE token + web-login password).

path "secret/data/pulse" {
  capabilities = ["read"]
}

path "secret/metadata/pulse" {
  capabilities = ["read", "list"]
}
