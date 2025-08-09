resource "proxmox_vm_qemu" "kasm" {
  for_each      = var.vm_configs

  vmid          = each.value.vm_id 
  name          = each.value.name
  target_node   = each.value.target_node

  clone         = "kasm-1.17-template"
  full_clone    = true
  
  cpu {
    sockets     = 1
    cores       = each.value.cores
  }
  scsihw        = "virtio-scsi-pci"
  memory        = each.value.memory
  onboot        = true 
  vm_state      = each.value.vm_state

  agent         = 1

  network {
    id          = 0
    model       = "virtio"
    bridge      = "vmbr1"
  }

  disk {
    slot        = "scsi0"
    size        = each.value.disk_size
    type        = "disk"
    storage     = "pve1-local-ssd-mirror"
  }

  tags          = "terraform,infra,vm"
}