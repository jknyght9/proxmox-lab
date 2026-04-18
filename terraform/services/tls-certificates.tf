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

# Deploy Vault listener cert to GlusterFS
resource "null_resource" "install_vault_cert" {
  depends_on = [vault_pki_secret_backend_cert.vault_listener]

  triggers = {
    cert_serial = vault_pki_secret_backend_cert.vault_listener.serial_number
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo mkdir -p /srv/gluster/nomad-data/vault-tls"

      echo '${vault_pki_secret_backend_cert.vault_listener.certificate}' | \
        ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo tee /srv/gluster/nomad-data/vault-tls/cert.pem > /dev/null"

      echo '${vault_pki_secret_backend_cert.vault_listener.private_key}' | \
        ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo tee /srv/gluster/nomad-data/vault-tls/key.pem > /dev/null"

      ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo chmod 644 /srv/gluster/nomad-data/vault-tls/cert.pem && sudo chmod 600 /srv/gluster/nomad-data/vault-tls/key.pem"
    EOT
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

# Deploy Traefik wildcard cert to GlusterFS
resource "null_resource" "install_traefik_cert" {
  count      = var.deploy_traefik ? 1 : 0
  depends_on = [vault_pki_secret_backend_cert.traefik_wildcard]

  triggers = {
    cert_serial = vault_pki_secret_backend_cert.traefik_wildcard[0].serial_number
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo mkdir -p /srv/gluster/nomad-data/traefik/tls"

      echo '${vault_pki_secret_backend_cert.traefik_wildcard[0].certificate}' | \
        ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo tee /srv/gluster/nomad-data/traefik/tls/cert.pem > /dev/null"

      echo '${vault_pki_secret_backend_cert.traefik_wildcard[0].private_key}' | \
        ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo tee /srv/gluster/nomad-data/traefik/tls/key.pem > /dev/null"

      ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo chmod 644 /srv/gluster/nomad-data/traefik/tls/cert.pem && sudo chmod 600 /srv/gluster/nomad-data/traefik/tls/key.pem"
    EOT
  }
}

# Deploy TLS dynamic config for Traefik file provider
resource "null_resource" "traefik_tls_config" {
  count      = var.deploy_traefik ? 1 : 0
  depends_on = [null_resource.install_traefik_cert]

  triggers = {
    cert_serial = vault_pki_secret_backend_cert.traefik_wildcard[0].serial_number
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo mkdir -p /srv/gluster/nomad-data/traefik/config"

      cat <<'TLSYML' | ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} "sudo tee /srv/gluster/nomad-data/traefik/config/tls.yml > /dev/null"
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /tls/cert.pem
        keyFile: /tls/key.pem
TLSYML
    EOT
  }
}
