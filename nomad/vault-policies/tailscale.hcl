# Tailscale policy - read auth key for subnet router
path "secret/data/infra/tailscale" {
  capabilities = ["read"]
}
