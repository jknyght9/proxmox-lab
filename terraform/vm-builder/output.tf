output "vm_ips" {
  description = "Map of build-runner VM names to their IP addresses"
  value       = { for k, v in var.vm_configs : k => v.ip }
}
