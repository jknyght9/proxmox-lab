terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      #version = "2.9.14"
      version = "3.0.2-rc04"
    }
  }
}

# Token authentication (default - configured by setup.sh)
provider "proxmox" {
  pm_api_url          = var.proxmox_api_url
  pm_api_token_id     = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token
  pm_tls_insecure     = true
}
