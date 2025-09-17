module "docker" {
  providers = {
    proxmox = proxmox
  }
  source = "./vm-docker-swarm"
  proxmox_bridge = var.network_interface_bridge
}

module "pihole" {
  providers = {
    proxmox = proxmox
  }
  source = "./lxc-pihole"
  root_password = var.pihole_root_password
  external_eth0_vmbr = var.network_interface_bridge
  external_eth0_ipv4_cidr = var.pihole_eth0_ipv4_cidr
  external_eth0_gw = var.network_gateway_address
  proxmox_api_url = var.proxmox_api_url
  proxmox_target_node = var.proxmox_target_node
}

module "step-ca" {
  providers = {
    proxmox = proxmox
  }
  source = "./lxc-step-ca"
  root_password = var.step-ca_root_password
  eth0_vmbr = var.network_interface_bridge
  eth0_ipv4_cidr = var.step-ca_eth0_ipv4_cidr
  eth0_gateway = var.network_gateway_address
  pihole_ipv4_cidr = var.pihole_eth0_ipv4_cidr
  proxmox_target_node = var.proxmox_target_node
}

module "kasm" {
  source = "./vm-kasm"
  proxmox_bridge = var.network_interface_bridge
}
