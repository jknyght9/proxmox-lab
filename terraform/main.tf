module "nomad" {
  depends_on = [module.dns-main]
  providers = {
    proxmox = proxmox
  }
  dns_postfix         = var.dns_postfix
  dns_primary_ip      = var.dns_primary_ipv4
  proxmox_api_url     = var.proxmox_api_url
  proxmox_bridge      = var.network_interface_bridge
  node_ip_map         = local.node_ip_map
  source              = "./vm-nomad"
  ssh_public_key_file = var.ssh_public_key_file
  vm_storage          = var.vm_storage

  # Traefik HA Configuration (keepalived VIP)
  traefik_ha_enabled        = var.nomad_traefik_ha_enabled
  traefik_ha_vip            = var.nomad_traefik_ha_vip
  traefik_ha_vrrp_router_id = var.nomad_traefik_ha_vrrp_router_id
  traefik_ha_vrrp_password  = var.nomad_traefik_ha_vrrp_password
}

# Main DNS cluster (one node per Proxmox cluster node, on external network)
module "dns-main" {
  providers = {
    proxmox = proxmox
  }
  source           = "./lxc-pihole"
  cluster_name     = "main"
  nodes            = local.effective_dns_main_nodes
  network_bridge   = var.network_interface_bridge
  storage          = var.lxc_storage
  admin_password   = var.pihole_admin_password
  root_password    = var.pihole_root_password
  proxmox_api_url  = var.proxmox_api_url
  vmid_start       = 910
  is_sdn_network   = false
  proxmox_ssh_host = local.proxmox_api_host
  node_ip_map      = local.node_ip_map
  dns_zone         = var.dns_postfix
  bootstrap_dns    = var.bootstrap_dns

  # HA Configuration (keepalived VIP)
  enable_ha_vip     = var.enable_dns_ha_vip
  ha_vip_address    = var.dns_ha_vip_address
  ha_vrrp_router_id = var.dns_ha_vrrp_router_id
  ha_vrrp_password  = var.dns_ha_vrrp_password
}

# Labnet SDN DNS cluster (max 2 nodes on SDN network)
module "dns-labnet" {
  providers = {
    proxmox = proxmox
  }
  source           = "./lxc-pihole"
  cluster_name     = "labnet"
  nodes            = local.effective_dns_labnet_nodes
  network_bridge   = "labnet"
  storage          = var.lxc_storage
  admin_password   = var.pihole_admin_password
  root_password    = var.pihole_root_password
  proxmox_api_url  = var.proxmox_api_url
  vmid_start       = 920
  is_sdn_network   = true
  proxmox_ssh_host = local.proxmox_api_host
  node_ip_map      = local.node_ip_map
  dns_zone         = var.dns_postfix
  bootstrap_dns    = var.bootstrap_dns

  # DHCP for labnet SDN (VMs need IP addresses)
  dhcp_enabled     = var.labnet_dhcp_enabled
  dhcp_start       = var.labnet_dhcp_start
  dhcp_end         = var.labnet_dhcp_end
  dhcp_router      = var.labnet_dhcp_router
  dhcp_lease_time  = var.labnet_dhcp_lease_time

  # HA Configuration (keepalived VIP)
  enable_ha_vip     = var.labnet_enable_dns_ha_vip
  ha_vip_address    = var.labnet_dns_ha_vip_address
  ha_vrrp_router_id = var.labnet_dns_ha_vrrp_router_id
  ha_vrrp_password  = var.labnet_dns_ha_vrrp_password
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
  dns_postfix         = var.dns_postfix
  proxmox_target_node = var.proxmox_target_node
  root_password       = var.step-ca_root_password
  bootstrap_dns       = var.bootstrap_dns

  # Optional second NIC for ACME validation to Proxmox management network
  eth1_enabled        = var.step-ca_eth1_enabled
  eth1_vmbr           = var.step-ca_eth1_vmbr
  eth1_ipv4_cidr      = var.step-ca_eth1_ipv4_cidr

  source              = "./lxc-step-ca"
}

module "kasm" {
  dns_postfix         = var.dns_postfix
  kasm_admin_password = var.kasm_admin_password
  kasm_version        = var.kasm_version
  proxmox_api_url     = var.proxmox_api_url
  proxmox_bridge      = var.network_interface_bridge
  source              = "./vm-kasm"
  ssh_public_key_file = var.ssh_public_key_file
  vm_storage          = var.vm_storage
}
