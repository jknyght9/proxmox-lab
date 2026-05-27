# =============================================================================
# TLS Certificates — issued from Vault PKI
# Replaces: bash cert issuance in deployVault.sh and deployTraefik.sh
# =============================================================================

# --- Vault Listener Certificate ---

resource "vault_pki_secret_backend_cert" "vault_listener" {
  depends_on = [vault_pki_secret_backend_role.acme_certs]

  backend     = vault_mount.pki_int.path
  name        = vault_pki_secret_backend_role.acme_certs.name
  common_name = "vault.${var.dns_postfix}"
  # SANs cover every Nomad node where Vault might run. Required for
  # Raft TLS — the leader presents this cert to peers and they verify
  # against their own configured server name.
  alt_names = concat(
    [for name, _ in var.nomad_node_ips : "${name}.${var.dns_postfix}"],
    ["localhost", "vault"]
  )
  ip_sans = concat(
    [for _, ip in var.nomad_node_ips : ip],
    ["127.0.0.1"]
  )
  ttl = "8760h" # 1 year
}

# Write cert + chain to a local temp file, then upload via file provisioner
resource "local_file" "vault_cert_pem" {
  filename = "${path.module}/rendered/vault-cert.pem"
  content  = "${vault_pki_secret_backend_cert.vault_listener.certificate}\n${vault_pki_secret_backend_cert.vault_listener.ca_chain}"
}

resource "local_file" "vault_key_pem" {
  filename        = "${path.module}/rendered/vault-key.pem"
  content         = vault_pki_secret_backend_cert.vault_listener.private_key
  file_permission = "0600"
}

resource "null_resource" "install_vault_cert" {
  # Push the listener cert to every Nomad VM. The cert dir is on
  # GlusterFS so technically a single push would replicate, but writing
  # from each node makes the dependency graph explicit and tolerates
  # any per-node read-after-write FS quirks.
  for_each = var.nomad_node_ips

  depends_on = [local_file.vault_cert_pem, local_file.vault_key_pem]

  triggers = {
    cert_serial = vault_pki_secret_backend_cert.vault_listener.serial_number
    host        = each.value
  }

  connection {
    type        = "ssh"
    host        = each.value
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = ["sudo mkdir -p /srv/gluster/nomad-data/vault-tls"]
  }

  provisioner "file" {
    source      = local_file.vault_cert_pem.filename
    destination = "/tmp/vault-cert.pem"
  }

  provisioner "file" {
    source      = local_file.vault_key_pem.filename
    destination = "/tmp/vault-key.pem"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cp /tmp/vault-cert.pem /srv/gluster/nomad-data/vault-tls/cert.pem",
      "sudo cp /tmp/vault-key.pem /srv/gluster/nomad-data/vault-tls/key.pem",
      "sudo chmod 644 /srv/gluster/nomad-data/vault-tls/cert.pem",
      "sudo chmod 644 /srv/gluster/nomad-data/vault-tls/key.pem",
      "rm -f /tmp/vault-cert.pem /tmp/vault-key.pem",
      "echo '[+] Vault listener cert installed on ${each.key} (full chain)'",
    ]
  }
}

# --- Traefik Wildcard Certificate ---
#
# Traefik mints its own cert via a Nomad `template` block that POSTs to
# pki_int/issue/acme-certs at startup and renews automatically. The
# terraform-side `vault_pki_secret_backend_cert.traefik_wildcard`,
# `local_file.traefik_{cert,key}_pem`, `null_resource.install_traefik_cert`,
# and `null_resource.traefik_tls_config` resources were removed in commit
# X (CSI migration prep) — terraform no longer owns Traefik's TLS material.
# See terraform/services/templates/traefik.nomad.hcl.tpl for the runtime
# fetch + reload-on-renew wiring.
