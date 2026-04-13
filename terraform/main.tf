locals {
  # Extract Proxmox API host from endpoint URL for SSH connections
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_endpoint)[0]

  # Build node IP map from variable
  node_ip_map = var.proxmox_node_ips

  # Effective DNS nodes: use configured list or fall back to empty
  effective_dns_main_nodes = length(var.dns_main_nodes) > 0 ? var.dns_main_nodes : []
}

# =============================================================================
# Nomad Cluster (3-node, cloned from Packer nomad-template)
# =============================================================================

module "nomad" {
  depends_on = [module.dns-main]

  source = "./vm-nomad"

  dns_postfix      = var.dns_postfix
  dns_primary_ip   = var.dns_primary_ipv4
  proxmox_endpoint = var.proxmox_endpoint
  proxmox_bridge   = var.network_interface_bridge
  node_ip_map      = local.node_ip_map
  vm_storage       = var.vm_storage
  template_node    = var.proxmox_target_node
  network_gateway  = var.network_gateway_address
  network_cidr_bits = split("/", var.dns_main_nodes[0].ip)[1]

  ssh_enterprise_private_key_file = var.ssh_enterprise_private_key_file
  ssh_admin_public_key_file       = var.ssh_admin_public_key_file
  ssh_admin_private_key_file      = replace(var.ssh_admin_public_key_file, ".pub", "")

  # Traefik HA Configuration (keepalived VIP)
  traefik_ha_enabled        = var.nomad_traefik_ha_enabled
  traefik_ha_vip            = var.nomad_traefik_ha_vip
  traefik_ha_vrrp_router_id = var.nomad_traefik_ha_vrrp_router_id
  traefik_ha_vrrp_password  = var.nomad_traefik_ha_vrrp_password
}

# =============================================================================
# Main DNS Cluster (Pi-hole LXC, one per Proxmox node)
# =============================================================================

module "dns-main" {
  source = "./lxc-pihole"

  cluster_name   = "main"
  nodes          = local.effective_dns_main_nodes
  network_bridge = var.network_interface_bridge
  storage        = var.lxc_storage
  admin_password = local.vault_configured ? data.vault_kv_secret_v2.pihole[0].data["admin_password"] : "vault-not-configured"
  root_password  = local.vault_configured ? data.vault_kv_secret_v2.pihole[0].data["root_password"] : "vault-not-configured"
  vmid_start     = 910
  is_sdn_network = false
  proxmox_ssh_host = local.proxmox_api_host
  node_ip_map    = local.node_ip_map
  dns_zone       = var.dns_postfix
  bootstrap_dns  = var.bootstrap_dns

  ssh_enterprise_private_key_file = var.ssh_enterprise_private_key_file
  ssh_admin_public_key_file       = var.ssh_admin_public_key_file
  ssh_admin_private_key_file      = replace(var.ssh_admin_public_key_file, ".pub", "")

  # HA Configuration (keepalived VIP)
  enable_ha_vip     = var.enable_dns_ha_vip
  ha_vip_address    = var.dns_ha_vip_address
  ha_vrrp_router_id = var.dns_ha_vrrp_router_id
  ha_vrrp_password  = var.dns_ha_vrrp_password
}

# =============================================================================
# Kasm Workspaces (cloned from Docker template)
# =============================================================================

module "kasm" {
  depends_on = [module.dns-main]

  source = "./vm-kasm"

  dns_postfix        = var.dns_postfix
  dns_primary_ip     = var.dns_primary_ipv4
  proxmox_endpoint   = var.proxmox_endpoint
  proxmox_bridge     = var.network_interface_bridge
  node_ip_map        = local.node_ip_map
  vm_storage         = var.vm_storage
  template_node      = var.proxmox_target_node
  network_gateway    = var.network_gateway_address
  network_cidr_bits  = split("/", var.dns_main_nodes[0].ip)[1]
  kasm_admin_password = local.vault_configured ? data.vault_kv_secret_v2.kasm[0].data["admin_password"] : "vault-not-configured"

  ssh_enterprise_private_key_file = var.ssh_enterprise_private_key_file
  ssh_admin_public_key_file       = var.ssh_admin_public_key_file
}

# NOTE: Labnet SDN DNS cluster has been moved to feature/labnet-sdn branch.
# It will be re-integrated once the SDN implementation is stabilized.

# NOTE: step-ca module has been replaced by Vault PKI secrets engine.
# Certificate Authority is now provided by Vault at:
#   - Root CA: https://vault.<domain>/v1/pki/ca/pem
#   - Intermediate: pki_int/issue/acme-certs
