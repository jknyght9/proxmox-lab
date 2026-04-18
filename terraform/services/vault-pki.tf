# =============================================================================
# Vault PKI — Root CA + Intermediate CA + ACME
# Replaces: initVaultPKI() in lib/deploy/nomadJob/deployVault.sh
# =============================================================================

locals {
  nomad01_ip = var.nomad_node_ips["nomad01"]
}

# --- Root CA (10-year TTL) ---

resource "vault_mount" "pki" {
  path                  = "pki"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 10 years
  description           = "Proxmox Lab Root CA"
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend     = vault_mount.pki.path
  type        = "internal"
  common_name = "Proxmox Lab Root CA"
  issuer_name = "proxmox-lab-root"
  key_type    = "ec"
  key_bits    = 256
  ttl         = "87600h" # 10 years
}

resource "vault_pki_secret_backend_config_urls" "root" {
  backend                 = vault_mount.pki.path
  issuing_certificates    = ["${var.vault_address}/v1/pki/ca"]
  crl_distribution_points = ["${var.vault_address}/v1/pki/crl"]
}

# --- Intermediate CA (5-year TTL) ---

resource "vault_mount" "pki_int" {
  path                  = "pki_int"
  type                  = "pki"
  max_lease_ttl_seconds = 157680000 # 5 years
  description           = "Proxmox Lab Intermediate CA"
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = "Proxmox Lab Intermediate CA"
  key_type    = "ec"
  key_bits    = 256
}

resource "vault_pki_secret_backend_root_sign_intermediate" "int" {
  backend     = vault_mount.pki.path
  csr         = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name = "Proxmox Lab Intermediate CA"
  issuer_ref  = vault_pki_secret_backend_root_cert.root.issuer_id
  ttl         = "43800h" # 5 years
}

resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.pki_int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.int.certificate
}

resource "vault_pki_secret_backend_config_urls" "int" {
  backend                 = vault_mount.pki_int.path
  issuing_certificates    = ["${var.vault_address}/v1/pki_int/ca"]
  crl_distribution_points = ["${var.vault_address}/v1/pki_int/crl"]
}

# --- ACME Role + Configuration ---

resource "vault_pki_secret_backend_role" "acme_certs" {
  backend                  = vault_mount.pki_int.path
  name                     = "acme-certs"
  allow_any_name           = true
  allow_ip_sans            = true
  allow_localhost           = true
  allow_bare_domains       = true
  allow_subdomains         = true
  allow_wildcard_certificates = true
  enforce_hostnames        = false
  server_flag              = true
  client_flag              = true
  key_type                 = "ec"
  key_bits                 = 256
  ttl                      = "2160h"  # 90 days
  max_ttl                  = "8760h"  # 1 year
}

# ACME config — enable ACME on the intermediate CA
resource "null_resource" "pki_acme_config" {
  depends_on = [vault_pki_secret_backend_role.acme_certs]

  triggers = {
    role = vault_pki_secret_backend_role.acme_certs.name
  }

  # Vault provider doesn't have a native ACME config resource yet,
  # so we use curl via the Vault address directly
  provisioner "local-exec" {
    command = <<-EOT
      curl -sk -X POST "${var.vault_address}/v1/pki_int/config/acme" \
        -H "X-Vault-Token: ${var.vault_token}" \
        -H "Content-Type: application/json" \
        -d '{"enabled":true,"default_directory_policy":"sign-verbatim","allowed_roles":["acme-certs"],"allow_role_ext_key_usage":true}'

      curl -sk -X POST "${var.vault_address}/v1/pki_int/config/cluster" \
        -H "X-Vault-Token: ${var.vault_token}" \
        -H "Content-Type: application/json" \
        -d '{"path":"https://${local.nomad01_ip}:8200/v1/pki_int"}'
    EOT
  }
}

# --- Root CA distribution to Nomad nodes ---

resource "null_resource" "install_root_ca" {
  for_each   = var.nomad_node_ips
  depends_on = [vault_pki_secret_backend_root_cert.root]

  triggers = {
    root_ca = vault_pki_secret_backend_root_cert.root.issuing_ca
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Fetch root CA PEM and install on node
      ROOT_CA=$(curl -sk "${var.vault_address}/v1/pki/ca/pem")
      ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${each.value} \
        "echo '$ROOT_CA' | sudo tee /usr/local/share/ca-certificates/proxmox-lab-root-ca.crt > /dev/null && sudo update-ca-certificates --fresh"
    EOT
  }
}

# --- Save root CA to GlusterFS for containers ---

resource "null_resource" "gluster_root_ca" {
  depends_on = [vault_pki_secret_backend_root_cert.root]

  triggers = {
    root_ca = vault_pki_secret_backend_root_cert.root.issuing_ca
  }

  provisioner "local-exec" {
    command = <<-EOT
      ROOT_CA=$(curl -sk "${var.vault_address}/v1/pki/ca/pem")
      ssh -o StrictHostKeyChecking=no -i ${var.ssh_admin_private_key_file} \
        labadmin@${local.nomad01_ip} \
        "sudo mkdir -p /srv/gluster/nomad-data/certs && echo '$ROOT_CA' | sudo tee /srv/gluster/nomad-data/certs/root_ca.crt > /dev/null"
    EOT
  }
}
