# =============================================================================
# Nomad-Vault Integration — update vault.hcl on nodes with real address
# Replaces: configureNomadVaultIntegration.sh
# =============================================================================

locals {
  # Vault address for Nomad's WIF integration. Each node talks to its OWN
  # Vault over loopback.
  #
  # NOT `https://vault.<dns_postfix>`: that name resolves to Traefik, and
  # Traefik's own jobspec carries a `vault {}` stanza, so Nomad adds the
  # implicit constraint `${attr.vault.version} semver >= 0.6.1`. No node can
  # fingerprint Vault through an address only Traefik can serve, so Traefik
  # never places and the deploy deadlocks — observed as `traefik 0 placed`
  # with zero `vault.version` node attributes.
  #
  # Loopback breaks the cycle with no loss of correctness: Vault is a system
  # job, so every node has a local peer, and the listener cert carries both
  # `localhost` (alt_names) and `127.0.0.1` (ip_sans) — see
  # tls-certificates.tf. Standby peers forward writes to the Raft leader, so
  # write HA is unaffected. The tradeoff versus the Traefik-fronted name is
  # that a node whose own Vault alloc is down cannot issue tokens to its own
  # workloads, instead of transparently borrowing a surviving peer.
  vault_addr_for_nomad = "https://localhost:8200"
}

resource "null_resource" "nomad_vault_config" {
  for_each   = var.nomad_node_ips
  depends_on = [vault_jwt_auth_backend.nomad]

  triggers = {
    vault_address = local.vault_addr_for_nomad
    root_ca       = vault_pki_secret_backend_root_cert.root.issuing_ca
  }

  connection {
    type        = "ssh"
    host        = each.value
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      echo '[+] Updating Vault configuration on ${each.key}...'
      sudo tee /etc/nomad.d/vault.hcl > /dev/null <<'VAULTCONF'
vault {
  enabled = true
  address = "${local.vault_addr_for_nomad}"

  default_identity {
    aud  = ["vault.io"]
    env  = false
    file = true
    ttl  = "1h"
  }
}
VAULTCONF
      sudo systemctl restart nomad
      echo '[+] Nomad restarted with Vault address: ${local.vault_addr_for_nomad}'
      EOT
    ]
  }
}
