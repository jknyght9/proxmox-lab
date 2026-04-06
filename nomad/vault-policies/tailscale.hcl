# Tailscale policy - read auth key for subnet router
path "secret/data/tailscale" {
  capabilities = ["read"]
}
