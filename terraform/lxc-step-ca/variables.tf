variable "vmid" {
  type = number
  default = 902
}

variable "root_password" {
  type = string
  description = "Step CA root password"
}

variable "eth0_vmbr" {
  type = string 
  description = "Proxmox bridge interface"

  validation {
    condition     = can(regex("^vmbr[0-9]+$", var.eth0_vmbr))
    error_message = "Bridge interface must be named like vmbr0, vmbr1, etc."
  }
}

variable "eth0_ipv4_cidr" {
  type = string
  description = "IPv4 address with CIDR notation for Step-CA"

  validation {
    condition     = can(cidrhost(var.eth0_ipv4_cidr, 0))
    error_message = "Must be a valid CIDR block."
  }
}

variable "eth0_gateway" {
  type = string
  description = "Gateway IPv4 address"
  
  validation {
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$", var.eth0_gateway))
    error_message = "Must be a valid IPv4 address."
  }
}