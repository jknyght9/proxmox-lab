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

# Main DNS cluster (3 nodes on external network)
module "dns-main" {
  providers = {
    proxmox = proxmox
  }
  source          = "./lxc-technitium"
  cluster_name    = "main"
  nodes           = var.dns_main_nodes
  network_bridge  = var.network_interface_bridge
  admin_password  = var.technitium_admin_password
  root_password   = var.technitium_root_password
  proxmox_api_url = var.proxmox_api_url
  vmid_start      = 910
}

# Labnet SDN DNS cluster (2 nodes)
module "dns-labnet" {
  providers = {
    proxmox = proxmox
  }
  source          = "./lxc-technitium"
  cluster_name    = "labnet"
  nodes           = var.dns_labnet_nodes
  network_bridge  = "labnet"
  admin_password  = var.technitium_admin_password
  root_password   = var.technitium_root_password
  proxmox_api_url = var.proxmox_api_url
  vmid_start      = 920
}

module "step-ca" {
  depends_on = [module.dns-main]
  providers = {
    proxmox = proxmox
  }
  eth0_vmbr           = var.network_interface_bridge
  eth0_ipv4_cidr      = var.step-ca_eth0_ipv4_cidr
  eth0_gateway        = var.network_gateway_address
  dns_primary_ipv4    = var.dns_primary_ipv4
  proxmox_target_node = var.proxmox_target_node
  root_password       = var.step-ca_root_password
  source              = "./lxc-step-ca"
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
