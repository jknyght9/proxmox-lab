locals {
  # Extract host from Proxmox API URL
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_api_url)[0]

  # Node IP map is passed from setup.sh via variable (set in terraform.tfvars)
  node_ip_map = var.proxmox_node_ips

  # DNS node configuration comes from terraform.tfvars (setup.sh generates these dynamically)
  effective_dns_main_nodes   = var.dns_main_nodes
  effective_dns_labnet_nodes = var.dns_labnet_nodes
}
