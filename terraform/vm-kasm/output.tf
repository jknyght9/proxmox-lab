output "vm_ips" {
  description = "Map of Kasm VM names to their IP addresses"
  value       = { for k, v in var.vm_configs : k => v.ip }
}
