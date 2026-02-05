locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_api_url)[0]
  nomad_servers    = join(",", [for k, v in var.vm_configs : "\"${v.name}.${var.dns_postfix}\""])
}

resource "local_file" "nomad_user_data" {
  for_each = var.vm_configs
  filename = "${path.module}/rendered/${each.value.name}-user-data.yml"
  content = templatefile("${path.module}/cloudinit/nomad-user-data.tmpl", {
    acme_dir              = "https://ca.${var.dns_postfix}/acme/acme/directory"
    dns_postfix           = var.dns_postfix
    dns_primary_ip        = var.dns_primary_ip
    hostname              = each.value.name
    sans                  = "${each.value.name}.${var.dns_postfix}"
    ssh_authorized_keys   = file(var.ssh_public_key_file)
    nomad_datacenter      = var.nomad_datacenter
    nomad_region          = var.nomad_region
    nomad_bootstrap_expect = length(var.vm_configs)
    nomad_servers         = local.nomad_servers
    gluster_mount         = var.gluster_mount_path
  })
}

resource "null_resource" "upload_snippet" {
  for_each   = var.vm_configs
  depends_on = [local_file.nomad_user_data]
  triggers = {
    sha = sha256(local_file.nomad_user_data[each.key].content)
  }
  connection {
    type        = "ssh"
    # Upload to the target node for this VM, fallback to API host
    host        = lookup(var.node_ip_map, each.value.target_node, local.proxmox_api_host)
    user        = "root"
    private_key = file("/crypto/lab-deploy")
  }
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /var/lib/vz/snippets",
    ]
  }
  provisioner "file" {
    source      = local_file.nomad_user_data[each.key].filename
    destination = "/var/lib/vz/snippets/${each.value.name}-user-data.yml"
  }
}

resource "proxmox_vm_qemu" "nomad" {
  for_each    = var.vm_configs

  vmid        = each.value.vm_id
  name        = each.value.name
  target_node = each.value.target_node

  clone       = "nomad-template"
  full_clone  = true

  agent       = 1
  onboot      = true
  vm_state    = each.value.vm_state

  cpu {
    sockets = 1
    cores   = each.value.cores
  }
  scsihw = "virtio-scsi-pci"
  memory = each.value.memory

  network {
    id     = 0
    model  = "virtio"
    bridge = var.proxmox_bridge
  }

  disk {
    slot    = "scsi0"
    size    = each.value.disk_size
    type    = "disk"
    storage = var.vm_storage
  }

  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.vm_storage
  }

  ciuser    = "labadmin"
  ipconfig0 = "ip=dhcp"
  sshkeys   = file("/crypto/lab-deploy.pub")
  cicustom  = "user=local:snippets/${each.value.name}-user-data.yml"
  tags      = "terraform,infra,vm,nomad"
}
