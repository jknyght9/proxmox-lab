output "docker" {
  value = module.docker.docker
  sensitive = true
}

output "pihole" {
  value = module.pihole
  sensitive = true
}

output "step-ca" {
  value = module.step-ca
  sensitive = true
}

output "kasm" {
  value = module.kasm.kasm
  sensitive = true
}

output "hosts" {
  value = {
    docker = module.docker.docker-hosts
    kasm = module.kasm.kasm-hosts
    pihole = module.pihole.pihole-hosts
    step-ca = module.step-ca.step-ca-hosts
  }
}

output "host-records" {
  value = {
    external = flatten([
      for group_hosts in [
        module.docker.docker-hosts, 
        module.kasm.kasm-hosts,
        module.pihole.pihole-external-host,
        module.step-ca.step-ca-hosts
      ] : [
        for name, details in group_hosts : {
          hostname  = details.hostname 
          ip        = details.ip 
        }
      ]
    ])
    internal = flatten([
      for group_hosts in [
        module.pihole.pihole-internal-host
      ] : [
        for name, details in group_hosts : {
          hostname    = details.hostname 
          ip          = details.ip 
        }
      ]
    ])
  }
}
