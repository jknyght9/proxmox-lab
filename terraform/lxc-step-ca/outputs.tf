output "step-ca" {
  sensitive = true
  value = {
    name      = proxmox_lxc.step-ca.hostname
    vmid      = proxmox_lxc.step-ca.vmid
    agent     = 0
    ip        = proxmox_lxc.step-ca.network[0].ip
    hostname  = proxmox_lxc.step-ca.hostname
    target    = proxmox_lxc.step-ca.target_node
  }
}

output "step-ca-hosts" {
  value = {
    step-ca = {
      hostname  = proxmox_lxc.step-ca.hostname
      ip        = proxmox_lxc.step-ca.network[0].ip
    }
  }
}
