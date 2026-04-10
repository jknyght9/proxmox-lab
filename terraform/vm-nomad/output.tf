output "nomad" {
  sensitive = true
  value = {
    for k, vm in proxmox_virtual_environment_vm.nomad :
    k => {
      name     = vm.name
      vmid     = vm.vm_id
      ip       = try(vm.ipv4_addresses[1][0], "pending")
      hostname = vm.name
      target   = vm.node_name
    }
  }
}

output "nomad-hosts" {
  value = {
    for name, details in proxmox_virtual_environment_vm.nomad : name => {
      hostname = details.name
      ip       = try(details.ipv4_addresses[1][0], "pending")
    }
  }
}
