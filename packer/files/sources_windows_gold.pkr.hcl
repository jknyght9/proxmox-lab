source "proxmox" "win10" {
  url                  = var.proxmox_url
  node                 = var.proxmox_node
  username             = var.proxmox_user
  token                = var.proxmox_token
  insecure_skip_tls_verify = true

  vm_id                = var.win10_vmid
  name                 = "win10-gold"
  template             = true
  cores                = 4
  memory               = 8192
  sockets              = 1
  disk_size            = "64G"
  storage_pool         = "pve1-local-ssd-mirror"
  network_adapters {
    model  = "virtio"
    bridge = "vmbr1"
  }
  iso_file             = var.win10_iso
  winrm_username       = "Administrator"
  winrm_password       = "ChangeMe123!"
  communicator         = "winrm"
  winrm_insecure       = true
}
