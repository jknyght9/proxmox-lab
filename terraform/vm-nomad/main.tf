locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_endpoint)[0]
  nomad_servers    = join(",", [for k, v in var.vm_configs : "\"${v.name}.${var.dns_postfix}\""])
  sorted_vm_keys   = sort(keys(var.vm_configs))
}

# Render cloud-init user data templates
resource "local_file" "nomad_user_data" {
  for_each = var.vm_configs
  filename = "${path.module}/rendered/${each.value.name}-user-data.yml"
  content = templatefile("${path.module}/cloudinit/nomad-user-data.tmpl", {
    acme_dir               = "https://vault.${var.dns_postfix}/v1/pki_int/acme/directory"
    dns_postfix            = var.dns_postfix
    dns_primary_ip         = var.dns_primary_ip
    hostname               = each.value.name
    sans                   = "${each.value.name}.${var.dns_postfix}"
    ssh_authorized_keys    = file(var.ssh_admin_public_key_file)
    nomad_datacenter       = var.nomad_datacenter
    nomad_region           = var.nomad_region
    nomad_bootstrap_expect = length(var.vm_configs)
    nomad_servers          = local.nomad_servers
    gluster_mount          = var.gluster_mount_path
    traefik_ha_enabled        = var.traefik_ha_enabled
    traefik_ha_vip            = var.traefik_ha_vip
    traefik_ha_node_index     = index(local.sorted_vm_keys, each.key)
    traefik_ha_vrrp_router_id = var.traefik_ha_vrrp_router_id
    traefik_ha_vrrp_password  = var.traefik_ha_vrrp_password
  })
}

# Upload cloud-init snippets to each Proxmox node via SSH
resource "null_resource" "upload_snippet" {
  for_each   = var.vm_configs
  depends_on = [local_file.nomad_user_data]
  triggers = {
    sha = sha256(local_file.nomad_user_data[each.key].content)
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
    source      = local_file.nomad_user_data[each.key].filename
    destination = "/var/lib/vz/snippets/${each.value.name}-user-data.yml"
  }
}

# Nomad cluster VMs (bpg/proxmox provider)
resource "proxmox_virtual_environment_vm" "nomad" {
  for_each   = var.vm_configs
  depends_on = [null_resource.upload_snippet]

  vm_id     = each.value.vm_id
  name      = each.value.name
  node_name = each.value.target_node
  on_boot   = true
  tags      = ["terraform", "infra", "vm", "nomad"]

  clone {
    vm_id = 9002  # nomad-template
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
        address = "dhcp"
      }
    }
    user_data_file_id = "local:snippets/${each.value.name}-user-data.yml"
  }

  lifecycle {
    ignore_changes = [
      disk[0].size,  # Don't resize on subsequent applies
    ]
  }
}
