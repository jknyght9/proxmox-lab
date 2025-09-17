variable "eth0_gateway" {
  type = string
  description = "Gateway IPv4 address"
  
  validation {
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$", var.eth0_gateway))
    error_message = "Must be a valid IPv4 address."
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

variable "eth0_vmbr" {
  type = string 
  description = "Proxmox bridge interface"

  validation {
    condition     = can(regex("^vmbr[0-9]+$", var.eth0_vmbr))
    error_message = "Bridge interface must be named like vmbr0, vmbr1, etc."
  }
}

variable "ostemplate" {
  type = string 
  description = "OS template for container"
  default = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "pihole_ipv4_cidr" {
  type = string
  description = "IPv4 address for Pihole instance"

  validation {
    condition     = can(cidrhost(var.pihole_ipv4_cidr, 0))
    error_message = "Must be a valid CIDR block."
  }
}

variable "proxmox_target_node" {
  type = string 
  description = "Proxmox node"
}

variable "root_password" {
  type = string
  description = "Step CA root password"
}

variable "vmid" {
  type = number
  default = 902
}