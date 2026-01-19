module "docker" {
  providers = {
    proxmox = proxmox
  }
  dns_postfix = var.dns_postfix
  proxmox_api_url = var.proxmox_api_url
  proxmox_bridge = var.network_interface_bridge
  source = "./vm-docker-swarm"
  ssh_public_key_file = var.ssh_public_key_file
}

module "pihole" {
  providers = {
    proxmox = proxmox
  }
  external_eth0_vmbr = var.network_interface_bridge
  external_eth0_ipv4_cidr = var.pihole_eth0_ipv4_cidr
  external_eth0_gw = var.network_gateway_address
  proxmox_api_url = var.proxmox_api_url
  proxmox_target_node = var.proxmox_target_node
  root_password = var.pihole_root_password
  source = "./lxc-pihole"
}

module "step-ca" {
  providers = {
    proxmox = proxmox
  }
  eth0_vmbr = var.network_interface_bridge
  eth0_ipv4_cidr = var.step-ca_eth0_ipv4_cidr
  eth0_gateway = var.network_gateway_address
  pihole_ipv4_cidr = var.pihole_eth0_ipv4_cidr
  proxmox_target_node = var.proxmox_target_node
  root_password = var.step-ca_root_password
  source = "./lxc-step-ca"
}

module "kasm" {
  dns_postfix = var.dns_postfix
  kasm_admin_password = var.kasm_admin_password
  kasm_version = var.kasm_version
  proxmox_api_url = var.proxmox_api_url
  proxmox_bridge = var.network_interface_bridge
  source = "./vm-kasm"
  ssh_public_key_file = var.ssh_public_key_file
}
