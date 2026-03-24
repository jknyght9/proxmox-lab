output "hosts" {
  value = {
    nomad      = try(module.nomad.nomad-hosts, {})
    kasm       = try(module.kasm.kasm-hosts, {})
    dns-main   = try(module.dns-main.dns-hosts, {})
    dns-labnet = length(module.dns-labnet) > 0 ? try(module.dns-labnet[0].dns-hosts, {}) : {}
    step-ca    = try(module.step-ca.step-ca-hosts, {})
  }
}

output "host-records" {
  value = {
    external = flatten([
      for group_hosts in [
        try(module.nomad.nomad-hosts, {}),
        try(module.kasm.kasm-hosts, {}),
        try(module.dns-main.dns-hosts, {}),
        try(module.step-ca.step-ca-hosts, {})
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
