locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_endpoint)[0]
}

# Render cloud-init user data templates
resource "local_file" "kasm_user_data" {
  for_each = var.vm_configs
  filename = "${path.module}/rendered/${each.value.name}-user-data.yml"
  content  = templatefile("${path.module}/cloudinit/kasm-user-data.tmpl", {
    dns_postfix         = var.dns_postfix
    hostname            = each.value.name
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
      # Use gateway DNS for initial provisioning — Pi-hole may not exist yet
      servers = [var.network_gateway]
      domain  = var.dns_postfix
    }
    user_data_file_id = "local:snippets/${each.value.name}-user-data.yml"
  }

  lifecycle {
    ignore_changes = [
      clone,
      disk[0].size,
    ]
  }
}

# =============================================================================
# Kasm Configuration (managed by Terraform, not cloud-init)
# =============================================================================

# Install Kasm Workspaces if not already installed
resource "null_resource" "kasm_install" {
  for_each   = var.vm_configs
  depends_on = [proxmox_virtual_environment_vm.kasm]

  triggers = {
    vm_id        = proxmox_virtual_environment_vm.kasm[each.key].vm_id
    kasm_version = var.kasm_version
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
      export HOME=/root
      cd /root

      if [ -x /opt/kasm/current/bin/start ]; then
        echo '[+] Kasm already installed, skipping'
        exit 0
      fi

      echo '[+] Installing Kasm Workspaces ${var.kasm_version}...'
      retry() { n=0; until "$@"; do n=$((n+1)); [ $n -ge 5 ] && return 1; sleep $((2*n)); done; }
      sudo curl -fsSLO https://kasm-static-content.s3.amazonaws.com/kasm_release_${var.kasm_version}.tar.gz
      sudo tar -xf kasm_release_${var.kasm_version}.tar.gz
      cd /root/kasm_release
      sudo retry bash install.sh --accept-eula --admin-password '${var.kasm_admin_password}'
      echo '[+] Kasm installation complete'
      EOT
    ]
  }
}

# Write ACME cert and renewal scripts
resource "null_resource" "kasm_cert_scripts" {
  for_each   = var.vm_configs
  depends_on = [null_resource.kasm_install]

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
      # Cert install script
      sudo tee /root/kasm-install.sh > /dev/null <<'CERTSCRIPT'
#!/bin/bash
set -e
/opt/kasm/current/bin/stop
/root/.acme.sh/acme.sh --set-default-ca --server https://vault.${var.dns_postfix}/v1/pki_int/acme/directory
/root/.acme.sh/acme.sh --issue --alpn -d ${each.value.name}.${var.dns_postfix} -d kasm.${var.dns_postfix}
KASM_CERT_DIR=/opt/kasm/current/certs
mkdir -p "$KASM_CERT_DIR"
for f in kasm_nginx.crt kasm_nginx.key; do
  [ -f "$KASM_CERT_DIR/$f" ] && mv "$KASM_CERT_DIR/$f" "$KASM_CERT_DIR/$f.bak" || true
done
/root/.acme.sh/acme.sh --install-cert -d ${each.value.name}.${var.dns_postfix} \
  --key-file       /opt/kasm/current/certs/kasm_nginx.key \
  --fullchain-file /opt/kasm/current/certs/kasm_nginx.crt
chown kasm:kasm /opt/kasm/current/certs/kasm_nginx.*
/opt/kasm/current/bin/start || true
CERTSCRIPT
      sudo chmod 755 /root/kasm-install.sh

      # Renewal script
      sudo tee /root/kasm-renew.sh > /dev/null <<'RENEWSCRIPT'
#!/bin/bash
/opt/kasm/current/bin/stop && sleep 2 && /opt/kasm/current/bin/start
RENEWSCRIPT
      sudo chmod 755 /root/kasm-renew.sh

      # Install ACME cron
      sudo bash -lc '
        export HOME=/root
        /root/.acme.sh/acme.sh --install-cronjob 2>/dev/null || true
        (crontab -l 2>/dev/null | grep -v kasm-renew; echo "0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh --reloadcmd \"/root/kasm-renew.sh\"") | crontab -
      '
      echo '[+] Kasm cert scripts configured on ${each.value.name}'
      EOT
    ]
  }
}
