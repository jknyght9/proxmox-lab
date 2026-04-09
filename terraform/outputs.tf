output "hosts" {
  value = {
    nomad      = try(module.nomad.nomad-hosts, {})
    kasm       = try(module.kasm.kasm-hosts, {})
    dns-main   = try(module.dns-main.dns-hosts, {})
    dns-labnet = length(module.dns-labnet) > 0 ? try(module.dns-labnet[0].dns-hosts, {}) : {}
    # Note: step-ca has been replaced by Vault PKI - no LXC container needed
  }
}

output "host-records" {
  value = {
    external = flatten([
      for group_hosts in [
        try(module.nomad.nomad-hosts, {}),
        try(module.kasm.kasm-hosts, {}),
        try(module.dns-main.dns-hosts, {})
        # Note: step-ca removed - CA is provided by Vault PKI
      ] : [
        for name, details in group_hosts : {
          hostname = details.hostname
          ip       = details.ip
        }
      ]
    ])
    internal = flatten([
      for group_hosts in [
        length(module.dns-labnet) > 0 ? try(module.dns-labnet[0].dns-hosts, {}) : {}
      ] : [
        for name, details in group_hosts : {
          hostname = details.hostname
          ip       = details.ip
        }
      ]
    ])
  }
}

output "dns-primary-ip" {
  description = "Primary DNS server IP for other services"
  value       = module.dns-main.primary_ip
}
