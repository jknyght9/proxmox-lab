output "nomad" {
  sensitive = true
  value = {
    for k, vm in proxmox_vm_qemu.nomad :
    k => {
      name     = vm.name
      vmid     = vm.vmid
      agent    = vm.agent
      ip       = vm.default_ipv4_address
      sship    = vm.ssh_host
      sshport  = vm.ssh_port
      hostname = vm.name
      target   = vm.target_node
    }
  }
}

output "nomad-hosts" {
  value = {
    for name, details in proxmox_vm_qemu.nomad : name => {
      hostname = details.name
      ip       = details.default_ipv4_address
    }
  }
}
