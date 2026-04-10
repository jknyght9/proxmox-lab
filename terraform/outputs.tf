output "hosts" {
  value = {
    nomad    = try(module.nomad.nomad-hosts, {})
    dns-main = try(module.dns-main.dns-hosts, {})
  }
}

output "host-records" {
  value = {
    external = flatten([
      for group_hosts in [
        try(module.nomad.nomad-hosts, {}),
        try(module.dns-main.dns-hosts, {})
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
