output "hosts" {
  value = {
    docker   = module.docker.docker-hosts
    kasm     = module.kasm.kasm-hosts
    dns-main = module.dns-main.dns-hosts
    dns-labnet = module.dns-labnet.dns-hosts
    step-ca  = module.step-ca.step-ca-hosts
  }
}

output "host-records" {
  value = {
    external = flatten([
      for group_hosts in [
        module.docker.docker-hosts,
        module.kasm.kasm-hosts,
        module.dns-main.dns-hosts,
        module.step-ca.step-ca-hosts
      ] : [
        for name, details in group_hosts : {
          hostname = details.hostname
          ip       = details.ip
        }
      ]
    ])
    internal = flatten([
      for group_hosts in [
        module.dns-labnet.dns-hosts
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
