variable "vmid_external" {
  type = number
  default = 900
}

variable "vmid_internal" {
  type = number
  default = 901
}

variable "vmid_template" {
  type = number
  default = 9002
}

variable "root_password" {
  type = string
  description = "Root password"
}

variable "external_eth0_vmbr" {
  type = string 
  description = "Proxmox bridge interface"

  validation {
    condition     = can(regex("^vmbr[0-9]+$", var.external_eth0_vmbr))
    error_message = "Bridge interface must be named like vmbr0, vmbr1, etc."
  }
}

variable "external_eth0_ipv4_cidr" {
  type = string
  description = "IPv4 address with CIDR notation for PiHole"

  validation {
    condition     = can(cidrhost(var.external_eth0_ipv4_cidr, 0))
    error_message = "Must be a valid CIDR block."
  }
}

variable "external_eth0_gw" {
  type = string
  description = "Gateway IPv4 address"
  
  validation {
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$", var.external_eth0_gw))
    error_message = "Must be a valid IPv4 address."
  }
}
variable "proxmox_api_url" {
  type = string
}
