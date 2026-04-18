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
