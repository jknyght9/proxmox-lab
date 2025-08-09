module "docker" {
  providers = {
    proxmox = proxmox
  }
  source = "./vm-docker-swarm"
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
}

module "kasm" {
  source = "./vm-kasm"
}
