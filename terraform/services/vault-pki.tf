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

# ACME configuration on the intermediate CA
resource "vault_pki_secret_backend_config_acme" "int" {
  backend                    = vault_mount.pki_int.path
  enabled                    = true
  default_directory_policy   = "sign-verbatim"
  allowed_roles              = [vault_pki_secret_backend_role.acme_certs.name]
  allow_role_ext_key_usage   = true
}

# Cluster path for ACME directory
resource "vault_pki_secret_backend_config_cluster" "int" {
  backend = vault_mount.pki_int.path
  path    = "https://${local.nomad01_ip}:8200/v1/pki_int"
}

# --- Root CA distribution to Nomad nodes ---

resource "null_resource" "install_root_ca" {
  for_each   = var.nomad_node_ips
  depends_on = [vault_pki_secret_backend_root_cert.root]

  triggers = {
    root_ca = vault_pki_secret_backend_root_cert.root.issuing_ca
  }

  connection {
    type        = "ssh"
    host        = each.value
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${vault_pki_secret_backend_root_cert.root.issuing_ca}' | sudo tee /usr/local/share/ca-certificates/proxmox-lab-root-ca.crt > /dev/null",
      "sudo update-ca-certificates --fresh",
      "echo '[+] Root CA installed on ${each.key}'",
    ]
  }
}

# --- Save root CA to GlusterFS for containers ---

resource "null_resource" "gluster_root_ca" {
  depends_on = [vault_pki_secret_backend_root_cert.root]

  triggers = {
    root_ca = vault_pki_secret_backend_root_cert.root.issuing_ca
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /srv/gluster/nomad-data/certs",
      "echo '${vault_pki_secret_backend_root_cert.root.issuing_ca}' | sudo tee /srv/gluster/nomad-data/certs/root_ca.crt > /dev/null",
      "echo '[+] Root CA saved to GlusterFS'",
    ]
  }
}
