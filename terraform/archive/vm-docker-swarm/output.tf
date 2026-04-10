output "docker" {
  sensitive = true
  value = {
    for k, vm in proxmox_vm_qemu.docker :
    k => {
      name      = vm.name 
      vmid      = vm.vmid 
      agent     = vm.agent
      ip        = vm.default_ipv4_address
      sship     = vm.ssh_host
      sshport   = vm.ssh_port
      hostname  = vm.name 
      target    = vm.target_node 
    }
  }
}

output "docker-hosts" {
  value = {
    for name, details in proxmox_vm_qemu.docker : name => {
      hostname  = details.name
      ip        = details.default_ipv4_address  
    }
  }
}