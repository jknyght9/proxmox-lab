locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_endpoint)[0]
  # Use IPs for retry_join — DNS names aren't available at boot time
  nomad_servers  = join(",", [for k, v in var.vm_configs : "\"${v.ip}\""])
  sorted_vm_keys = sort(keys(var.vm_configs))

  # Static IPs — known from vm_configs, no guest agent discovery needed
  vm_ips     = { for k, v in var.vm_configs : k => v.ip }
  master_key = local.sorted_vm_keys[0]
  master_ip  = local.vm_ips[local.master_key]
  all_ips    = [for k in local.sorted_vm_keys : local.vm_ips[k]]

  # Effective IP for internal service FQDNs baked into /etc/hosts.
  # Uses the Traefik HA VIP if set, otherwise nomad01.
  internal_vip_ip = var.traefik_ha_vip != "" ? split("/", var.traefik_ha_vip)[0] : local.master_ip

  # Rendered cloud-init hosts.debian.tmpl override — single source of
  # truth, embedded in cloud-init for fresh VMs and pushed to existing
  # VMs by null_resource.hosts_template_override.
  hosts_template_content = templatefile("${path.module}/cloudinit/hosts.debian.tmpl.tpl", {
    internal_vip_ip = local.internal_vip_ip
    dns_postfix     = var.dns_postfix
  })

  peer_ips = [for k in local.sorted_vm_keys : local.vm_ips[k] if k != local.master_key]
}

# Render cloud-init user data templates
resource "local_file" "nomad_user_data" {
  for_each = var.vm_configs
  filename = "${path.module}/rendered/${each.value.name}-user-data.yml"
  content = templatefile("${path.module}/cloudinit/nomad-user-data.tmpl", {
    dns_postfix             = var.dns_postfix
    hostname                = each.value.name
    ssh_authorized_keys     = file(var.ssh_admin_public_key_file)
    hosts_template_content  = local.hosts_template_content
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
    sockets = each.value.sockets
    cores   = each.value.cores
    type    = each.value.cpu_type
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
    nomad_servers    = local.nomad_servers
    nomad_datacenter = var.nomad_datacenter
    nomad_region     = var.nomad_region
    vm_ip            = each.value.ip
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

      # Nomad reads /etc/nomad.d/*.hcl on startup. The systemd unit was
      # enabled during the Packer build, so Nomad is already running with
      # whatever config was on disk at boot — without raw_exec enabled,
      # docker volumes allowed, etc. Restart so the new config takes
      # effect.
      sudo systemctl restart nomad
      echo '[+] Nomad configuration written and reloaded on ${each.value.name}'
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

# GlusterFS removed in Phase 3 of the storage migration — all services
# moved either to CSI/NFS on the cluster_state NAS or to local disk
# per Nomad VM. Previous resources here:
#   - null_resource.gluster_brick_setup    (per-VM brick dir creation)
#   - null_resource.gluster_init           (peer probe + volume create + tuning)
#   - null_resource.gluster_mount          (fstab entry + mount on each VM)
#   - null_resource.gluster_mount_sentinel (sentinel file for wait-for-gluster prestart)
#   - null_resource.traefik_config         (push authentik.yml to gluster — now
#                                           inlined in the traefik Nomad template
#                                           via a `template {}` stanza)
# See plans/serene-brewing-cray.md for the migration arc.

# Restart Nomad on each node after nomad_config writes /etc/nomad.d/nomad.hcl.
resource "null_resource" "nomad_restart" {
  for_each   = var.vm_configs
  depends_on = [null_resource.nomad_config]

  triggers = {
    nomad_config = null_resource.nomad_config[each.key].id
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

# Step 5a: Point each Nomad VM at the Pi-hole DNS resolver. Cloud-init
# uses gateway DNS so apt/acme can run on first boot (before Pi-hole
# exists), but post-deploy we want internal DNS so vault.<domain>,
# auth.<domain>, etc. resolve — Nomad's Vault fingerprint and JWT login
# both require it. Gateway is kept as fallback in case Pi-hole is down.
locals {
  pihole_netplan_yaml = <<-NETPLAN
    network:
      version: 2
      ethernets:
        eth0:
          nameservers:
            addresses: [${var.dns_primary_ip}, ${var.network_gateway}]
            search: [${var.dns_postfix}]
  NETPLAN
}

# Push the augmented /etc/cloud/templates/hosts.debian.tmpl to each Nomad
# VM and refresh /etc/hosts now. Cloud-init's write_files only runs at
# instance creation, so this exists to update already-deployed VMs and to
# regenerate /etc/hosts on every change without waiting for a reboot.
resource "null_resource" "hosts_template_override" {
  for_each   = var.vm_configs
  depends_on = [null_resource.nomad_restart]

  triggers = {
    content = local.hosts_template_content
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "file" {
    content     = local.hosts_template_content
    destination = "/tmp/hosts.debian.tmpl"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo install -m 644 -o root -g root /tmp/hosts.debian.tmpl /etc/cloud/templates/hosts.debian.tmpl",
      "rm /tmp/hosts.debian.tmpl",
      # Regenerate /etc/hosts now so we don't need a reboot. The
      # `update_etc_hosts` cloud-init module is what reads the template
      # under manage_etc_hosts:true; --frequency always forces re-run.
      "sudo cloud-init single --name cc_update_etc_hosts --frequency always 2>/dev/null || sudo cloud-init single --name update_etc_hosts --frequency always",
      "echo '[+] /etc/hosts regenerated on ${each.value.name}'",
      "getent hosts vault.${var.dns_postfix} auth.${var.dns_postfix} traefik.${var.dns_postfix}",
    ]
  }
}

resource "null_resource" "nomad_dns_switch" {
  for_each   = var.dns_primary_ip != "" ? var.vm_configs : {}
  depends_on = [null_resource.nomad_restart]

  triggers = {
    yaml = local.pihole_netplan_yaml
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "file" {
    content     = local.pihole_netplan_yaml
    destination = "/tmp/99-pihole-dns.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo install -m 600 -o root -g root /tmp/99-pihole-dns.yaml /etc/netplan/99-pihole-dns.yaml",
      "rm /tmp/99-pihole-dns.yaml",
      "sudo netplan apply",
      "echo '[+] DNS switched to Pi-hole (${var.dns_primary_ip}) on ${each.value.name}'",
    ]
  }
}

# Step 5b: Wait for Nomad cluster to form (all servers joined)
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
