# =============================================================================
# Nomad-Vault Integration — update vault.hcl on nodes with real address
# Replaces: configureNomadVaultIntegration.sh
# =============================================================================

locals {
  # HA-aware Vault address for Nomad's WIF integration.
  # `https://vault.<dns_postfix>` resolves to Traefik via Pi-hole, which
  # load-balances across all 3 healthy Vault peers. Standby peers
  # forward writes to the leader; reads on standby are served directly.
  # If any single Vault dies, Traefik routes to a survivor — Nomad
  # workloads keep getting tokens with no manual intervention.
  vault_addr_for_nomad = "https://vault.${var.dns_postfix}"
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
