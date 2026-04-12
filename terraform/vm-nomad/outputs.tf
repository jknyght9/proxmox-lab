output "vm_ips" {
  description = "Map of Nomad VM names to their IP addresses"
  value       = local.vm_ips
}

output "master_ip" {
  description = "IP address of the primary Nomad node (nomad01)"
  value       = local.master_ip
}
