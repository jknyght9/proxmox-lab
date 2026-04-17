locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_endpoint)[0]
}

# Render cloud-init user data templates
resource "local_file" "kasm_user_data" {
  for_each = var.vm_configs
  filename = "${path.module}/rendered/${each.value.name}-user-data.yml"
  content  = templatefile("${path.module}/cloudinit/kasm-user-data.tmpl", {
    acme_dir            = "https://vault.${var.dns_postfix}/v1/pki_int/acme/directory"
    dns_postfix         = var.dns_postfix
    hostname            = each.value.name
    kasm_admin_password = var.kasm_admin_password
    kasm_download_url   = "https://kasm-static-content.s3.amazonaws.com/kasm_release_${var.kasm_version}.tar.gz"
    kasm_version        = var.kasm_version
    sans                = "${each.value.name}.${var.dns_postfix} kasm.${var.dns_postfix}"
    ssh_authorized_keys = file(var.ssh_admin_public_key_file)
  })
}

# Upload cloud-init snippets to Proxmox node via SSH
resource "null_resource" "upload_snippet" {
  for_each   = var.vm_configs
  depends_on = [local_file.kasm_user_data]
  triggers = {
    sha = sha256(local_file.kasm_user_data[each.key].content)
  }
  connection {
    type        = "ssh"
    host        = lookup(var.node_ip_map, each.value.target_node, local.proxmox_api_host)
    user        = "root"
    private_key = file(var.ssh_enterprise_private_key_file)
  }
  provisioner "remote-exec" {
    inline = ["mkdir -p /var/lib/vz/snippets"]
  }
  provisioner "file" {
    source      = local_file.kasm_user_data[each.key].filename
    destination = "/var/lib/vz/snippets/${each.value.name}-user-data.yml"
  }
}

# Kasm VM (bpg/proxmox provider)
resource "proxmox_virtual_environment_vm" "kasm" {
  for_each   = var.vm_configs
  depends_on = [null_resource.upload_snippet]

  vm_id     = each.value.vm_id
  name      = each.value.name
  node_name = each.value.target_node
  on_boot   = true
  tags      = ["terraform", "infra", "vm", "kasm"]

  clone {
    vm_id     = 9001 # docker-template
    node_name = var.template_node
  }

  agent {
    enabled = true
  }

  cpu {
    sockets = 1
    cores   = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    interface    = "scsi0"
    size         = tonumber(replace(each.value.disk_size, "G", ""))
    datastore_id = var.vm_storage
  }

  network_device {
    bridge = var.proxmox_bridge
    model  = "virtio"
  }

  initialization {
    user_account {
      username = "labadmin"
      keys     = [trimspace(file(var.ssh_admin_public_key_file))]
    }
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_cidr_bits}"
        gateway = var.network_gateway
      }
    }
    dns {
      servers = [var.dns_primary_ip != "" ? var.dns_primary_ip : var.network_gateway]
      domain  = var.dns_postfix
    }
    user_data_file_id = "local:snippets/${each.value.name}-user-data.yml"
  }

  lifecycle {
    ignore_changes = [
      disk[0].size,
    ]
  }
}
