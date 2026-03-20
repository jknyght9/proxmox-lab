locals {
  proxmox_api_host   = regex("^https?://([^:/]+)", var.proxmox_api_url)[0]
  kasm_template     = join(".", slice((split(".", var.kasm_version)), 0, 2))
}

resource "local_file" "kasm_user_data" {
  for_each = var.vm_configs
  filename = "${path.module}/rendered/${each.value.name}-user-data.yml"
  content  = templatefile("${path.module}/cloudinit/kasm-user-data.tmpl", {
    acme_dir            = "https://ca.${var.dns_postfix}/acme/acme/directory"
    dns_postfix         = "${var.dns_postfix}"
    hostname            = each.value.name
    kasm_admin_password = "${var.kasm_admin_password}"
    kasm_download_url   = "https://kasm-static-content.s3.amazonaws.com/kasm_release_${var.kasm_version}.tar.gz"
    kasm_version        = "${var.kasm_version}"
    sans                = "${each.value.name}.${var.dns_postfix} kasm.${var.dns_postfix}",
    ssh_authorized_keys = file(var.ssh_admin_public_key_file)  # Admin key for VM access
  })
}

resource "null_resource" "upload_snippet" {
  for_each = var.vm_configs
  depends_on = [local_file.kasm_user_data]
  triggers = {
    sha = sha256(local_file.kasm_user_data[each.key].content)
  }
  connection {
    type        = "ssh"
    host        = local.proxmox_api_host
    user        = "root"
    private_key = file(var.ssh_enterprise_private_key_file)  # Enterprise key for Proxmox access
  }
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /var/lib/vz/snippets",
    ]
  }
  provisioner "file" {
    source      = local_file.kasm_user_data[each.key].filename
    destination = "/var/lib/vz/snippets/${each.value.name}-user-data.yml"
  }
}

resource "proxmox_vm_qemu" "kasm" {
  for_each      = var.vm_configs

  vmid          = each.value.vm_id 
  name          = each.value.name
  target_node   = each.value.target_node

  clone         = "docker-template"
  full_clone    = true
  
  agent         = 1
  onboot        = true 
  vm_state      = each.value.vm_state
  cpu {
    sockets     = 1
    cores       = each.value.cores
  }
  scsihw        = "virtio-scsi-pci"
  memory        = each.value.memory
  
  network {
    id          = 0
    model       = "virtio"
    bridge      = var.proxmox_bridge
  }

  disk {
    slot        = "scsi0"
    size        = each.value.disk_size
    type        = "disk"
    storage     = var.vm_storage
  }

  disk {
    slot        = "ide2"
    type        = "cloudinit"
    storage     = var.vm_storage
  }

  ciuser        = "labadmin"
  ipconfig0     = "ip=dhcp"
  sshkeys       = file(var.ssh_admin_public_key_file)  # Admin key for VM access
  cicustom      = "user=local:snippets/${each.value.name}-user-data.yml"

  tags          = "terraform,infra,vm"
}