output "hosts" {
  value = {
    docker     = try(module.docker.docker-hosts, {})
    kasm       = try(module.kasm.kasm-hosts, {})
    dns-main   = try(module.dns-main.dns-hosts, {})
    dns-labnet = try(module.dns-labnet.dns-hosts, {})
    step-ca    = try(module.step-ca.step-ca-hosts, {})
  }
}

output "host-records" {
  value = {
    external = flatten([
      for group_hosts in [
        try(module.docker.docker-hosts, {}),
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
        try(module.dns-labnet.dns-hosts, {})
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
