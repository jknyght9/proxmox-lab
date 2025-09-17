source "proxmox-clone" "ubuntu-docker" {
  task_timeout          = "5m"
  proxmox_url           = var.proxmox_url
  node                  = var.proxmox_node
  username              = var.proxmox_token_id
  token                 = var.proxmox_token_secret
  insecure_skip_tls_verify = true

  vm_id                 = var.docker_vmid
  vm_name               = var.docker_name
  
  #clone_vm              = "ubuntu-server-24.04"
  clone_vm_id           = 9999
  ssh_username          = var.ssh_username
  ssh_password          = var.ssh_password
  ssh_private_key_file  = var.ssh_private_key_file

  cores                 = 2
  memory                = 4096
  sockets               = 1
  
  scsi_controller       = "virtio-scsi-pci"

  network_adapters {
    model               = "virtio"
    bridge              = "vmbr0"
  }

  tags                  = "linux;packer;template;vm"
}
