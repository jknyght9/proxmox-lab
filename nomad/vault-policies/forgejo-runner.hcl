# Vault policy for the Forgejo Actions runner job
# Allows the runner to read its registration token and the internal root CA.

# Registration token, minted from the live Forgejo instance by
# null_resource.forgejo_runner_token and written here (not by Terraform).
path "secret/data/forgejo-runner" {
  capabilities = ["read"]
}

path "secret/metadata/forgejo-runner" {
  capabilities = ["read", "list"]
}

# Root CA cert so the Nomad template stanza can write it to
# /local/certs/root_ca.crt — the runner's SSL_CERT_FILE points there to
# validate the HTTPS hop to git.<postfix> against the internal CA.
path "pki/cert/ca" {
  capabilities = ["read"]
}
