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
variable "ssh_public_key_file" { 
  type = string 
  default = "/crypto/lab-deploy.pub"
}