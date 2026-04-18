terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
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

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}

provider "nomad" {
  # Nomad may not exist during initial bootstrap (terraform apply -target=module.nomad).
  # Address defaults to localhost:4646 — set nomad_address in tfvars after cluster deploys.
  # Resources gated by count = local.nomad_configured won't make API calls until then.
  address = var.nomad_address
}

provider "vault" {
  # Vault may not exist during initial bootstrap (terraform apply -target=module.nomad).
  # Use dummy values so the provider initializes without error; data sources with
  # count = 0 won't make API calls.
  address          = var.vault_address != "" ? var.vault_address : "https://127.0.0.1:8200"
  token            = var.vault_token != "" ? var.vault_token : "not-configured"
  skip_tls_verify  = true # Internal CA — workstation may not trust it
  skip_child_token = true
}
