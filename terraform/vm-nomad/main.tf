locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_endpoint)[0]
  # Use IPs for retry_join — DNS names aren't available at boot time
  nomad_servers    = join(",", [for k, v in var.vm_configs : "\"${v.ip}\""])
  sorted_vm_keys   = sort(keys(var.vm_configs))

  # GlusterFS configuration
  gluster_brick  = "/data/gluster/${var.gluster_volume_name}"
  gluster_volume = var.gluster_volume_name

  # Static IPs — known from vm_configs, no guest agent discovery needed
  vm_ips = { for k, v in var.vm_configs : k => v.ip }
  master_key  = local.sorted_vm_keys[0]
  master_ip   = local.vm_ips[local.master_key]
  all_ips     = [for k in local.sorted_vm_keys : local.vm_ips[k]]
  peer_ips    = [for k in local.sorted_vm_keys : local.vm_ips[k] if k != local.master_key]
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
    vm_id     = 9002  # nomad-template (on primary node)
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
      disk[0].size,  # Don't resize on subsequent applies
    ]
  }
}

# =============================================================================
# GlusterFS Cluster Setup (replaces setupNomadCluster bash function)
# =============================================================================

# Step 1: Create brick directories on each node
resource "null_resource" "gluster_brick_setup" {
  for_each   = var.vm_configs
  depends_on = [proxmox_virtual_environment_vm.nomad]

  triggers = {
    vm_id = proxmox_virtual_environment_vm.nomad[each.key].vm_id
  }

  connection {
    type        = "ssh"
    host        = local.vm_ips[each.key]
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "echo '[+] Setting up GlusterFS brick on ${each.value.name}...'",
      "sudo mkdir -p ${local.gluster_brick}",
      "sudo mkdir -p ${var.gluster_mount_path}",
    ]
  }
}

# Step 2: Initialize GlusterFS cluster from master node (peer probe + volume create)
resource "null_resource" "gluster_init" {
  depends_on = [null_resource.gluster_brick_setup]

  triggers = {
    cluster_ips = join(",", local.all_ips)
  }

  connection {
    type        = "ssh"
    host        = local.master_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = flatten([
      "echo '[+] Initializing GlusterFS cluster from ${local.master_ip}...'",

      # Peer probe all other nodes
      [for ip in local.peer_ips : "sudo gluster peer probe ${ip}"],
      "sleep 3",
      "sudo gluster pool list",

      # Create replicated volume (skip if already exists)
      "sudo gluster volume info ${local.gluster_volume} >/dev/null 2>&1 || sudo gluster volume create ${local.gluster_volume} replica ${length(local.all_ips)} ${join(" ", [for ip in local.all_ips : "${ip}:${local.gluster_brick}"])} force",
      "sudo gluster volume info ${local.gluster_volume} | grep -q 'Status: Started' || sudo gluster volume start ${local.gluster_volume}",

      # Set recommended GlusterFS options
      "sudo gluster volume set ${local.gluster_volume} cluster.quorum-type auto || true",
      "sudo gluster volume set ${local.gluster_volume} cluster.self-heal-daemon on || true",
      "sudo gluster volume set ${local.gluster_volume} cluster.data-self-heal on || true",
      "sudo gluster volume set ${local.gluster_volume} cluster.metadata-self-heal on || true",
      "sudo gluster volume set ${local.gluster_volume} cluster.entry-self-heal on || true",
      "sudo gluster volume set ${local.gluster_volume} performance.client-io-threads on || true",
      "sudo gluster volume set ${local.gluster_volume} network.ping-timeout 10 || true",

      "echo '[+] GlusterFS volume ${local.gluster_volume} ready'",
    ])
  }
}

# Step 3: Mount GlusterFS and configure fstab on all nodes
resource "null_resource" "gluster_mount" {
  for_each   = var.vm_configs
  depends_on = [null_resource.gluster_init]

  triggers = {
    volume = local.gluster_volume
  }

  connection {
    type        = "ssh"
    host        = local.vm_ips[each.key]
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "echo '[+] Mounting GlusterFS on ${each.value.name}...'",
      "sudo mkdir -p ${var.gluster_mount_path}",
      "grep -q ':/${local.gluster_volume}' /etc/fstab || echo 'localhost:/${local.gluster_volume} ${var.gluster_mount_path} glusterfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab >/dev/null",
      "mountpoint -q ${var.gluster_mount_path} || sudo mount -t glusterfs localhost:/${local.gluster_volume} ${var.gluster_mount_path}",
      "echo '[+] GlusterFS mounted at ${var.gluster_mount_path}'",
    ]
  }
}

# Step 4: Restart Nomad and wait for cluster to form
resource "null_resource" "nomad_cluster_health" {
  depends_on = [null_resource.gluster_mount]

  connection {
    type        = "ssh"
    host        = local.master_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = flatten([
      # Restart Nomad on all nodes (GlusterFS mount is now available)
      [for ip in local.all_ips :
        "ssh -o StrictHostKeyChecking=no ${ip} 'sudo systemctl restart nomad'"
      ],

      # Wait for all servers to join
      <<-EOT
      echo '[+] Waiting for Nomad cluster to form...'
      for i in $(seq 1 30); do
        COUNT=$(nomad server members 2>/dev/null | grep -c alive || echo 0)
        if [ "$COUNT" -eq ${length(local.all_ips)} ]; then
          echo "[+] Nomad cluster healthy: $COUNT/${length(local.all_ips)} servers"
          nomad server members
          exit 0
        fi
        echo "    Waiting... ($i/30) $COUNT/${length(local.all_ips)} servers"
        sleep 5
      done
      echo '[!] Nomad cluster may not be fully formed'
      nomad server members
      exit 1
      EOT
    ])
  }
}
