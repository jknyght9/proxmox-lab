# =============================================================================
# Nomad-Vault Integration — update vault.hcl on nodes with real address
# Replaces: configureNomadVaultIntegration.sh
# =============================================================================

resource "null_resource" "nomad_vault_config" {
  for_each   = var.nomad_node_ips
  depends_on = [vault_jwt_auth_backend.nomad]

  triggers = {
    vault_address = var.vault_address
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
  address = "${var.vault_address}"

  default_identity {
    aud  = ["vault.io"]
    env  = false
    file = true
    ttl  = "1h"
  }
}
VAULTCONF
      sudo systemctl restart nomad
      echo '[+] Nomad restarted with Vault address: ${var.vault_address}'
      EOT
    ]
  }
}
