output "nomad_ips" {
  description = "Nomad cluster node IPs"
  value       = module.nomad.vm_ips
}

output "nomad_master" {
  description = "Nomad primary node IP (nomad01)"
  value       = module.nomad.master_ip
}

output "dns_ips" {
  description = "Pi-hole DNS container IPs"
  value       = try({ for k, v in module.dns-main.dns-hosts : k => v.ip }, {})
}

output "vault_address" {
  description = "Vault API address"
  value       = var.vault_address != "" ? var.vault_address : "http://${module.nomad.master_ip}:8200"
}

output "kasm_ip" {
  description = "Kasm Workspaces IP"
  value       = try(module.kasm[0].vm_ips["kasm01"], "not deployed")
}
