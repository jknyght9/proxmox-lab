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
  alt_names   = ["nomad01.${var.dns_postfix}", "localhost", "vault"]
  ip_sans     = [local.nomad01_ip, "127.0.0.1"]
  ttl         = "8760h" # 1 year
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
  depends_on = [local_file.vault_cert_pem, local_file.vault_key_pem]

  triggers = {
    cert_serial = vault_pki_secret_backend_cert.vault_listener.serial_number
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
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
      "echo '[+] Vault listener cert installed (full chain)'",
    ]
  }
}

# --- Traefik Wildcard Certificate ---

resource "vault_pki_secret_backend_cert" "traefik_wildcard" {
  count      = var.deploy_traefik ? 1 : 0
  depends_on = [vault_pki_secret_backend_role.acme_certs]

  backend     = vault_mount.pki_int.path
  name        = vault_pki_secret_backend_role.acme_certs.name
  common_name = "*.${var.dns_postfix}"
  alt_names   = [var.dns_postfix]
  ttl         = "8760h" # 1 year
}

resource "local_file" "traefik_cert_pem" {
  count    = var.deploy_traefik ? 1 : 0
  filename = "${path.module}/rendered/traefik-cert.pem"
  content  = "${vault_pki_secret_backend_cert.traefik_wildcard[0].certificate}\n${vault_pki_secret_backend_cert.traefik_wildcard[0].ca_chain}"
}

resource "local_file" "traefik_key_pem" {
  count           = var.deploy_traefik ? 1 : 0
  filename        = "${path.module}/rendered/traefik-key.pem"
  content         = vault_pki_secret_backend_cert.traefik_wildcard[0].private_key
  file_permission = "0600"
}

resource "null_resource" "install_traefik_cert" {
  count      = var.deploy_traefik ? 1 : 0
  depends_on = [local_file.traefik_cert_pem, local_file.traefik_key_pem]

  triggers = {
    cert_serial = vault_pki_secret_backend_cert.traefik_wildcard[0].serial_number
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = ["sudo mkdir -p /srv/gluster/nomad-data/traefik/tls"]
  }

  provisioner "file" {
    source      = local_file.traefik_cert_pem[0].filename
    destination = "/tmp/traefik-cert.pem"
  }

  provisioner "file" {
    source      = local_file.traefik_key_pem[0].filename
    destination = "/tmp/traefik-key.pem"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cp /tmp/traefik-cert.pem /srv/gluster/nomad-data/traefik/tls/cert.pem",
      "sudo cp /tmp/traefik-key.pem /srv/gluster/nomad-data/traefik/tls/key.pem",
      "sudo chmod 644 /srv/gluster/nomad-data/traefik/tls/cert.pem",
      "sudo chmod 644 /srv/gluster/nomad-data/traefik/tls/key.pem",
      "rm -f /tmp/traefik-cert.pem /tmp/traefik-key.pem",
      "echo '[+] Traefik wildcard cert installed (full chain)'",
    ]
  }
}

# Deploy TLS dynamic config for Traefik file provider
resource "null_resource" "traefik_tls_config" {
  count      = var.deploy_traefik ? 1 : 0
  depends_on = [null_resource.install_traefik_cert]

  triggers = {
    cert_serial = vault_pki_secret_backend_cert.traefik_wildcard[0].serial_number
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /srv/gluster/nomad-data/traefik/config",
      <<-EOT
      sudo tee /srv/gluster/nomad-data/traefik/config/tls.yml > /dev/null <<'TLSYML'
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /data/traefik/tls/cert.pem
        keyFile: /data/traefik/tls/key.pem
TLSYML
      EOT
      ,
      "echo '[+] Traefik TLS config deployed'",
    ]
  }
}
