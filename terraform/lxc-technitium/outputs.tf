output "dns-hosts" {
  description = "Map of DNS hosts with their details"
  value = {
    for hostname, node in local.nodes_map : hostname => {
      hostname    = proxmox_lxc.dns[hostname].hostname
      ip          = proxmox_lxc.dns[hostname].network[0].ip
      vmid        = proxmox_lxc.dns[hostname].vmid
      target_node = proxmox_lxc.dns[hostname].target_node
    }
  }
}

output "primary_ip" {
  description = "IP address of the primary DNS node (for other services to use)"
  value       = local.primary_ip
}

output "dns_ips" {
  description = "List of all DNS server IPs"
  value       = [for hostname, node in local.nodes_map : node.ip_bare]
}

output "cluster_name" {
  description = "Name of this DNS cluster"
  value       = var.cluster_name
}
