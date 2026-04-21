terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.4.0"
    }
    pihole = {
      source  = "ryanwholey/pihole"
      version = "~> 0.0.6"
    }
  }
}

provider "vault" {
  address          = var.vault_address
  token            = var.vault_token
  skip_tls_verify  = true
  skip_child_token = true
}

provider "nomad" {
  address = var.nomad_address
}

provider "pihole" {
  url      = var.deploy_dns_records ? "http://${var.dns_server_ip}" : "http://127.0.0.1"
  password = var.deploy_dns_records ? var.pihole_admin_password : "not-configured"
}
