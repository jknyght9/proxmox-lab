output "pihole-internal" {
  sensitive = false
  value = {
    name      = proxmox_lxc.pihole-internal.hostname
    vmid      = proxmox_lxc.pihole-internal.vmid
    agent     = 0
    ip        = proxmox_lxc.pihole-internal.network[0].ip
    hostname  = proxmox_lxc.pihole-internal.hostname
    target    = proxmox_lxc.pihole-internal.target_node
  }
}

output "pihole-external" {
  sensitive = false
  value = {
    name      = proxmox_lxc.pihole-external.hostname
    vmid      = proxmox_lxc.pihole-external.vmid
    agent     = 0
    ip        = proxmox_lxc.pihole-external.network[0].ip
    hostname  = proxmox_lxc.pihole-external.hostname
    target    = proxmox_lxc.pihole-external.target_node
  }
}

output "pihole-internal-host" {
  value = {
    internal = {
      hostname    = proxmox_lxc.pihole-internal.hostname 
      ip          = proxmox_lxc.pihole-internal.network[0].ip
    }
  }
}

output "pihole-external-host" {
  value = {
    external = {
      hostname    = proxmox_lxc.pihole-external.hostname
      ip          = proxmox_lxc.pihole-external.network[0].ip
    }
  }
}

output "pihole-hosts" {
  value = {
    pihole-external = {
      hostname  = proxmox_lxc.pihole-external.hostname 
      ip        = proxmox_lxc.pihole-external.network[0].ip 
    }
    pihole-internal = {
      hostname  = proxmox_lxc.pihole-internal.hostname 
      ip        = proxmox_lxc.pihole-internal.network[0].ip 
    }
  }
}

