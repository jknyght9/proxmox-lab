terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      #version = "2.9.14"
      version = "3.0.2-rc03"
    }
  }
}

# Password authentication
provider proxmox {
  pm_api_url          = var.proxmox_api_url
  pm_user             = var.proxmox_api_username 
  pm_password         = var.proxmox_api_password
  pm_tls_insecure     = true
}

# Token authentication
# provider "proxmox" {
#   pm_api_url          = var.proxmox_api_url
#   pm_api_token_id     = var.proxmox_api_token_id
#   pm_api_token_secret = var.proxmox_api_token
#   pm_tls_insecure     = true

#   pm_debug            = true
#   pm_log_enable       = true
#   pm_log_file         = "terraform-proxmox-debug.log"
# }
