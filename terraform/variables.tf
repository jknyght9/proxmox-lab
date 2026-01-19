variable "dns_postfix" {
  type = string
  description = "Domain Name Service (DNS) postfix configured"
}
variable "kasm_admin_password" {
  type = string 
  default = "changeme123"
}
variable "kasm_version" { 
  type = string
  default = "1.17.0.7f020d"
}
variable network_interface_bridge {
  type = string
  description = "Network interface for all traffic"
}
variable network_gateway_address {
  type = string
  description = "Network gateway IP address"
}
variable proxmox_api_password {
  type = string 
  description = "Proxmox password for authentication"
}
variable proxmox_api_token {
  type = string
  description = "Proxmox API Token for authentication"
}
variable proxmox_api_token_id {
  type = string
  description = "Proxmox API Token ID for authentication"
}
variable proxmox_api_url {
  type = string
  description = "Proxmox API URL"
}
variable proxmox_api_username {
  type = string 
  description = "Proxmox username for authentication"
}
variable "proxmox_target_node" {
  type = string 
  description = "Proxmox node"
}
variable "technitium_admin_password" {
  type        = string
  description = "Technitium DNS admin password"
  sensitive   = true
}

variable "technitium_root_password" {
  type        = string
  description = "Technitium container root password"
  sensitive   = true
}

variable "dns_main_nodes" {
  type = list(object({
    hostname    = string
    target_node = string
    ip          = string
    gw          = string
  }))
  description = "Main DNS cluster nodes configuration"
  default = [
    { hostname = "dns-01", target_node = "pve-01", ip = "10.1.50.3/24", gw = "10.1.50.1" },
    { hostname = "dns-02", target_node = "pve-02", ip = "10.1.50.4/24", gw = "10.1.50.1" },
    { hostname = "dns-03", target_node = "pve-03", ip = "10.1.50.5/24", gw = "10.1.50.1" },
  ]
}

variable "dns_labnet_nodes" {
  type = list(object({
    hostname    = string
    target_node = string
    ip          = string
    gw          = string
  }))
  description = "Labnet SDN DNS cluster nodes configuration"
  default = [
    { hostname = "labnet-dns-01", target_node = "pve-01", ip = "172.16.0.3/24", gw = "172.16.0.1" },
    { hostname = "labnet-dns-02", target_node = "pve-02", ip = "172.16.0.4/24", gw = "172.16.0.1" },
  ]
}

variable "dns_primary_ipv4" {
  type        = string
  description = "Primary DNS server IP address (for other services)"
  default     = "10.1.50.3"
}
variable step-ca_root_password {
  type = string
  description = "Step CA container root password"
}
variable step-ca_eth0_ipv4_cidr {
  type = string
  description = "IPv4 address with CIDR notation for Step CA"
}
variable "ssh_public_key_file" { 
  type = string 
  default = "/crypto/lab-deploy.pub"
}