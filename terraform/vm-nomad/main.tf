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

  # Rendered Traefik authentik middleware config
  traefik_authentik_yml = templatefile("${path.module}/templates/traefik-authentik.yml.tpl", {
    dns_postfix = var.dns_postfix
    nomad01_ip  = local.vm_ips[local.sorted_vm_keys[0]]
    nomad_ips   = local.all_ips
    dns01_ip    = var.dns_primary_ip
  })
  peer_ips    = [for k in local.sorted_vm_keys : local.vm_ips[k] if k != local.master_key]
}

# Render cloud-init user data templates
resource "local_file" "nomad_user_data" {
  for_each = var.vm_configs
  filename = "${path.module}/rendered/${each.value.name}-user-data.yml"
  content = templatefile("${path.module}/cloudinit/nomad-user-data.tmpl", {
    dns_postfix         = var.dns_postfix
    hostname            = each.value.name
    ssh_authorized_keys = file(var.ssh_admin_public_key_file)
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
      # Use gateway DNS for initial provisioning — Pi-hole may not exist yet.
      # Cloud-init user-data switches to Pi-hole (dns_primary_ip) after boot.
      servers = [var.network_gateway]
      domain  = var.dns_postfix
    }
    user_data_file_id = "local:snippets/${each.value.name}-user-data.yml"
  }

  lifecycle {
    ignore_changes = [
      clone,         # Cloned VMs can't be re-cloned; ignore after creation
      disk[0].size,  # Don't resize on subsequent applies
    ]
  }
}

# =============================================================================
# GlusterFS Cluster Setup (replaces setupNomadCluster bash function)
# =============================================================================
# Nomad Configuration (managed by Terraform, not cloud-init)
# =============================================================================

# Write /etc/nomad.d/nomad.hcl on each node via SSH.
# Re-triggers on any config variable change — no VM recreation needed.
resource "null_resource" "nomad_config" {
  for_each   = var.vm_configs
  depends_on = [proxmox_virtual_environment_vm.nomad]

  triggers = {
    nomad_servers          = local.nomad_servers
    nomad_datacenter       = var.nomad_datacenter
    nomad_region           = var.nomad_region
    gluster_mount          = var.gluster_mount_path
    vm_ip                  = each.value.ip
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      echo '[+] Writing Nomad configuration on ${each.value.name}...'
      sudo tee /etc/nomad.d/nomad.hcl > /dev/null <<'NOMADCONF'
datacenter = "${var.nomad_datacenter}"
region     = "${var.nomad_region}"
data_dir   = "/opt/nomad/data"
bind_addr  = "0.0.0.0"

advertise {
  http = "{{ GetPrivateIP }}:4646"
  rpc  = "{{ GetPrivateIP }}:4647"
  serf = "{{ GetPrivateIP }}:4648"
}

server {
  enabled          = true
  bootstrap_expect = ${length(var.vm_configs)}

  server_join {
    retry_join     = [${local.nomad_servers}]
    retry_max      = 10
    retry_interval = "15s"
  }
}

client {
  enabled = true

  host_volume "gluster-data" {
    path      = "${var.gluster_mount_path}"
    read_only = false
  }
}

plugin "docker" {
  config {
    allow_privileged = true
    volumes {
      enabled = true
    }
  }
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}

consul {
  auto_advertise   = false
  server_auto_join = false
  client_auto_join = false
}
NOMADCONF

      # Vault WIF skeleton — placeholder address until Vault is deployed.
      # Layer 2 (terraform/services/) updates this with the real address.
      sudo tee /etc/nomad.d/vault.hcl > /dev/null <<'VAULTCONF'
vault {
  enabled = true
  address = "https://127.0.0.1:8200"

  default_identity {
    aud  = ["vault.io"]
    env  = false
    file = true
    ttl  = "1h"
  }
}
VAULTCONF

      echo '[+] Nomad configuration written on ${each.value.name}'
      EOT
    ]
  }
}

# Write ACME cert install script on each node
resource "null_resource" "nomad_cert_script" {
  for_each   = var.vm_configs
  depends_on = [proxmox_virtual_environment_vm.nomad]

  triggers = {
    dns_postfix = var.dns_postfix
    hostname    = each.value.name
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      sudo tee /root/nomad-cert-install.sh > /dev/null <<'CERTSCRIPT'
#!/bin/bash
set -e
mkdir -p /etc/nomad.d/tls
/root/.acme.sh/acme.sh --set-default-ca --server https://vault.${var.dns_postfix}/v1/pki_int/acme/directory
/root/.acme.sh/acme.sh --issue --alpn -d ${each.value.name}.${var.dns_postfix}
/root/.acme.sh/acme.sh --install-cert -d ${each.value.name}.${var.dns_postfix} \
  --key-file       /etc/nomad.d/tls/nomad.key \
  --fullchain-file /etc/nomad.d/tls/nomad.crt
CERTSCRIPT
      sudo chmod 755 /root/nomad-cert-install.sh
      echo '[+] ACME cert script written on ${each.value.name}'
      EOT
    ]
  }
}

# =============================================================================
# GlusterFS Cluster Setup
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
      # Hardened fstab line — the x-systemd.* options make the generated
      # mount unit depend on glusterd, and nofail keeps a bad mount from
      # blocking boot. Pairs with the RequiresMountsFor drop-ins baked
      # into the Packer image for docker.service and nomad.service so
      # neither service starts before the mount is up. Idempotent:
      # replaces any pre-existing gluster line.
      "sudo sed -i '\\|^localhost:/${local.gluster_volume}[[:space:]]|d' /etc/fstab",
      "echo 'localhost:/${local.gluster_volume} ${var.gluster_mount_path} glusterfs defaults,_netdev,nofail,x-systemd.requires=glusterd.service,x-systemd.after=glusterd.service 0 0' | sudo tee -a /etc/fstab >/dev/null",
      "sudo systemctl daemon-reload",
      "mountpoint -q ${var.gluster_mount_path} || sudo mount -t glusterfs localhost:/${local.gluster_volume} ${var.gluster_mount_path}",
      "echo '[+] GlusterFS mounted at ${var.gluster_mount_path}'",
    ]
  }
}

# Step 3b: Write the .mount-sentinel marker that per-job wait-for-gluster
# prestart tasks read to confirm the volume is really mounted (not a
# pre-mount empty local directory). Written through a single node —
# gluster replicates it to all peers.
resource "null_resource" "gluster_mount_sentinel" {
  depends_on = [null_resource.gluster_mount]

  triggers = {
    volume = local.gluster_volume
  }

  connection {
    type        = "ssh"
    host        = local.master_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "printf 'v1\\n' | sudo tee ${var.gluster_mount_path}/.mount-sentinel >/dev/null",
      "sudo chmod 644 ${var.gluster_mount_path}/.mount-sentinel",
    ]
  }
}

# Step 4: Deploy Traefik middleware config to GlusterFS (replaces envsubst in deployTraefik.sh)
resource "null_resource" "traefik_config" {
  depends_on = [null_resource.gluster_mount]

  triggers = {
    config_hash = sha256(local.traefik_authentik_yml)
  }

  connection {
    type        = "ssh"
    host        = local.master_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${var.gluster_mount_path}/traefik/config",
      "sudo mkdir -p ${var.gluster_mount_path}/traefik/tls",
    ]
  }

  provisioner "file" {
    content     = local.traefik_authentik_yml
    destination = "/tmp/authentik.yml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cp /tmp/authentik.yml ${var.gluster_mount_path}/traefik/config/authentik.yml",
      "sudo chmod 644 ${var.gluster_mount_path}/traefik/config/authentik.yml",
      "rm /tmp/authentik.yml",
      "echo '[+] Traefik authentik middleware config deployed'",
    ]
  }
}

# Step 5: Restart Nomad on each node (after GlusterFS mount + config written)
resource "null_resource" "nomad_restart" {
  for_each   = var.vm_configs
  depends_on = [null_resource.gluster_mount, null_resource.nomad_config]

  triggers = {
    gluster_mount = null_resource.gluster_mount[each.key].id
    nomad_config  = null_resource.nomad_config[each.key].id
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "echo '[+] Restarting Nomad on ${each.value.name}...'",
      "sudo systemctl restart nomad",
    ]
  }
}

# Step 5: Wait for Nomad cluster to form (all servers joined)
resource "null_resource" "nomad_cluster_health" {
  depends_on = [null_resource.nomad_restart]

  connection {
    type        = "ssh"
    host        = local.master_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
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
    ]
  }
}

# ============================================================================
# Traefik HA — keepalived VIP (configurable without VM recreation)
# ============================================================================

# Configure keepalived on each Nomad node when HA is enabled.
# Keepalived is pre-installed by Packer; this resource writes the config
# and starts/stops the service. Re-triggers on any HA setting change.
resource "null_resource" "traefik_keepalived" {
  for_each   = var.traefik_ha_enabled ? var.vm_configs : {}
  depends_on = [null_resource.nomad_cluster_health]

  triggers = {
    ha_enabled = var.traefik_ha_enabled
    vip        = var.traefik_ha_vip
    router_id  = var.traefik_ha_vrrp_router_id
    password   = var.traefik_ha_vrrp_password
    node_index = index(local.sorted_vm_keys, each.key)
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e
      NODE_INDEX=${index(local.sorted_vm_keys, each.key)}
      PRIORITY=$((101 - NODE_INDEX))
      if [ $NODE_INDEX -eq 0 ]; then STATE="MASTER"; else STATE="BACKUP"; fi

      echo "[+] Configuring Traefik keepalived on ${each.value.name} ($STATE, priority $PRIORITY)..."

      sudo tee /usr/local/bin/check-traefik-health.sh > /dev/null <<'HEALTHSCRIPT'
#!/bin/bash
curl -sf http://127.0.0.1:8081/ping > /dev/null 2>&1
exit $?
HEALTHSCRIPT
      sudo chmod 755 /usr/local/bin/check-traefik-health.sh

      sudo mkdir -p /etc/keepalived
      sudo tee /etc/keepalived/keepalived.conf > /dev/null <<KEEPCONF
vrrp_script check_traefik {
    script "/usr/local/bin/check-traefik-health.sh"
    interval 2
    weight -20
    fall 3
    rise 2
}

vrrp_instance TRAEFIK_VIP {
    state $STATE
    interface eth0
    virtual_router_id ${var.traefik_ha_vrrp_router_id}
    priority $PRIORITY
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass ${var.traefik_ha_vrrp_password}
    }

    virtual_ipaddress {
        ${var.traefik_ha_vip}
    }

    track_script {
        check_traefik
    }
}
KEEPCONF

      sudo systemctl enable keepalived
      sudo systemctl restart keepalived
      echo "[+] Keepalived configured and started on ${each.value.name}"
      EOT
    ]
  }
}

# Disable keepalived when HA is turned off
resource "null_resource" "traefik_keepalived_disable" {
  for_each   = !var.traefik_ha_enabled ? var.vm_configs : {}
  depends_on = [null_resource.nomad_cluster_health]

  triggers = {
    ha_enabled = var.traefik_ha_enabled
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "sudo systemctl disable keepalived 2>/dev/null || true",
      "sudo systemctl stop keepalived 2>/dev/null || true",
      "echo '[+] Keepalived disabled on ${each.value.name}'",
    ]
  }
}
