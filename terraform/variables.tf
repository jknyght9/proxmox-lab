variable proxmox_api_url {
  type = string
  description = "Proxmox API URL"
}

variable proxmox_api_token_id {
  type = string
  description = "Proxmox API Token ID for authentication"
}

variable proxmox_api_token {
  type = string
  description = "Proxmox API Token for authentication"
}

variable proxmox_api_username {
  type = string 
  description = "Proxmox username for authentication"
}

variable proxmox_api_password {
  type = string 
  description = "Proxmox password for authentication"
}

variable "proxmox_target_node" {
  type = string 
  description = "Proxmox node"
}

variable network_interface_bridge {
  type = string
  description = "Network interface for all traffic"
}

variable network_gateway_address {
  type = string
  description = "Network gateway IP address"
}

variable pihole_root_password {
  type = string
  description = "Pihole container root password"
}

variable pihole_eth0_ipv4_cidr {
  type = string
  description = "IPv4 address with CIDR notation for PiHole"
}

variable step-ca_root_password {
  type = string
  description = "Step CA container root password"
}

variable step-ca_eth0_ipv4_cidr {
  type = string
  description = "IPv4 address with CIDR notation for Step CA"
}
