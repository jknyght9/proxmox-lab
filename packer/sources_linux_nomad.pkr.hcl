source "proxmox-clone" "ubuntu-nomad" {
  task_timeout             = "5m"
  proxmox_url              = var.proxmox_url
  node                     = var.proxmox_node
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true

  vm_id                    = var.nomad_vmid
  vm_name                  = var.nomad_name

  clone_vm_id              = 9999
  ssh_username             = var.ssh_username
  ssh_password             = var.ssh_password
  ssh_timeout              = "10m"
  ssh_handshake_attempts   = 20

  cores                    = 2
  memory                   = 4096
  sockets                  = 1

  scsi_controller          = "virtio-scsi-pci"

  network_adapters {
    model                  = "virtio"
    bridge                 = var.network_bridge
  }

  tags                     = "linux;packer;template;vm;nomad"
}
