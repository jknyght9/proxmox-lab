locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_api_url)[0]

  # Default SSH host (fallback)
  default_ssh_host = var.proxmox_ssh_host != "" ? var.proxmox_ssh_host : local.proxmox_api_host

  # Create a map from hostname to node config for for_each
  nodes_map = { for idx, node in var.nodes : node.hostname => merge(node, {
    index    = idx
    vmid     = var.vmid_start + idx
    ip_bare  = regex("^([^/]+)", node.ip)[0]
    # SSH host for this container's Proxmox node (use node_ip_map if available, else default)
    ssh_host = lookup(var.node_ip_map, node.target_node, local.default_ssh_host)
  }) }

  # First node is the primary for Gravity Sync
  primary_node     = var.nodes[0]
  primary_ip       = regex("^([^/]+)", local.primary_node.ip)[0]
  primary_ssh_host = lookup(var.node_ip_map, local.primary_node.target_node, local.default_ssh_host)

  # Read unbound config file
  unbound_conf = file("${path.module}/files/unbound.conf")
}

resource "proxmox_lxc" "dns" {
  for_each = local.nodes_map

  target_node     = each.value.target_node
  vmid            = each.value.vmid
  hostname        = each.value.hostname
  ostemplate      = var.ostemplate
  password        = var.root_password
  ssh_public_keys = file("/crypto/lab-deploy.pub")
  unprivileged    = true

  cores  = var.cores
  memory = var.memory
  swap   = var.memory
  start  = true
  onboot = true

  rootfs {
    storage = var.storage
    size    = var.disk_size
  }

  network {
    name   = "eth0"
    bridge = var.network_bridge
    ip     = each.value.ip
    gw     = each.value.gw
  }

  features {
    nesting = true
  }

  tags = "terraform,lxc,dns,${var.cluster_name}"
}

# Direct SSH provisioning (only for non-SDN networks)
resource "null_resource" "direct_provision" {
  for_each   = var.is_sdn_network ? {} : local.nodes_map
  depends_on = [proxmox_lxc.dns]

  triggers = {
    vmid = proxmox_lxc.dns[each.key].vmid
  }

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/crypto/lab-deploy")
    host        = each.value.ip_bare
  }

  # Copy unbound config file
  provisioner "file" {
    content     = local.unbound_conf
    destination = "/tmp/pi-hole-unbound.conf"
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      set -e
      export DEBIAN_FRONTEND=noninteractive
      export PATH="/usr/local/bin:$PATH"

      # Use public DNS for package installation
      cp /etc/resolv.conf /etc/resolv.conf.bak || true
      echo "nameserver 1.1.1.1" > /etc/resolv.conf

      echo "[+] Updating package lists..."
      apt-get update

      echo "[+] Installing dependencies..."
      apt-get install -y curl wget apt-transport-https dnsutils jq unbound sqlite3

      echo "[+] Configuring Unbound for DNS-over-TLS..."
      # Wipe and replace the main config
      cat > /etc/unbound/unbound.conf <<'UNBOUNDMAIN'
include: "/etc/unbound/unbound.conf.d/pi-hole.conf"
UNBOUNDMAIN

      mv /tmp/pi-hole-unbound.conf /etc/unbound/unbound.conf.d/pi-hole.conf

      systemctl enable unbound
      systemctl restart unbound

      # Test unbound is working
      sleep 2
      echo "[+] Testing Unbound..."
      dig @127.0.0.1 -p 5335 google.com +short || echo "[!] Unbound test failed, continuing..."

      echo "[+] Installing Pi-hole..."
      mkdir -p /etc/pihole
      cat > /etc/pihole/setupVars.conf <<'SETUPVARS'
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=0.0.0.0/24
IPV6_ADDRESS=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
DNSMASQ_LISTENING=single
PIHOLE_DNS_1=127.0.0.1#5335
SETUPVARS

      # Install Pi-hole unattended
      curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended

      echo "[+] Configuring Pi-hole v6..."
      # Use pihole-FTL --config for Pi-hole v6
      pihole-FTL --config dns.upstreams '["127.0.0.1#5335"]'
      pihole-FTL --config dns.listeningMode ALL
      pihole-FTL --config webserver.api.password '${var.admin_password}'

      systemctl restart pihole-FTL

      # Keep public DNS for now - will be restored after gravity sync setup
      echo "[OK] Pi-hole + Unbound installation complete on ${each.key}"
    EOT
    ]
  }
}

# Nebula-Sync setup on primary node (non-SDN) - syncs TO replica nodes
resource "null_resource" "nebula_sync_setup" {
  depends_on = [null_resource.direct_provision]

  # Only run if there's more than one node (need replicas to sync to)
  count = !var.is_sdn_network && length(var.nodes) > 1 ? 1 : 0

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/crypto/lab-deploy")
    host        = local.primary_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      set -e
      export PATH="/usr/local/bin:$PATH"

      # Ensure we have public DNS for downloading
      echo "nameserver 1.1.1.1" > /etc/resolv.conf

      echo "[+] Installing Nebula-Sync on primary node (${local.primary_node.hostname})..."

      # Install curl if not available
      apt-get update -qq && apt-get install -y -qq curl

      # Download Nebula-Sync binary
      cd /tmp && \
      curl -sSL -o nebula-sync.tar.gz \
        https://github.com/lovelaze/nebula-sync/releases/download/v0.11.1/nebula-sync_0.11.1_linux_amd64.tar.gz && \
      tar -xzf nebula-sync.tar.gz && \
      mv nebula-sync /usr/local/bin/nebula-sync && \
      rm -f nebula-sync.tar.gz
      chmod +x /usr/local/bin/nebula-sync

      # Build replica list (all nodes except first/primary)
      REPLICAS="${join(",", [for idx, node in var.nodes : "http://${regex("^([^/]+)", node.ip)[0]}|${var.admin_password}" if idx > 0])}"

      # Create environment file with secrets (restricted permissions)
      mkdir -p /etc/nebula-sync
      cat > /etc/nebula-sync/env <<ENVEOF
PRIMARY=http://127.0.0.1|${var.admin_password}
REPLICAS=$REPLICAS
FULL_SYNC=true
RUN_GRAVITY=true
HTTP_ENABLED=false
ENVEOF
      chmod 600 /etc/nebula-sync/env

      # Create systemd service for Nebula-Sync
      cat > /etc/systemd/system/nebula-sync.service <<'SERVICEEOF'
[Unit]
Description=Nebula-Sync Pi-hole synchronization
After=network.target pihole-FTL.service

[Service]
Type=oneshot
EnvironmentFile=/etc/nebula-sync/env
ExecStart=/usr/local/bin/nebula-sync run
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

      # Create systemd timer to run every 5 minutes
      cat > /etc/systemd/system/nebula-sync.timer <<'TIMEREOF'
[Unit]
Description=Run Nebula-Sync every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
TIMEREOF

      # Enable and start the timer
      systemctl daemon-reload
      systemctl enable nebula-sync.timer
      systemctl start nebula-sync.timer

      # Run initial sync
      echo "[+] Running initial Nebula-Sync..."
      systemctl start nebula-sync.service || echo "[!] Initial sync may have failed, will retry on timer"

      echo "[OK] Nebula-Sync configured on primary node"
      echo "    Syncing to: $REPLICAS"

      # Switch back to local DNS
      echo "nameserver 127.0.0.1" > /etc/resolv.conf
    EOT
    ]
  }
}

# Finalize primary node DNS after nebula sync setup
resource "null_resource" "finalize_primary_dns" {
  depends_on = [null_resource.nebula_sync_setup, null_resource.direct_provision]

  count = !var.is_sdn_network ? 1 : 0

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/crypto/lab-deploy")
    host        = local.primary_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      # Switch primary node to use local DNS
      echo "nameserver 127.0.0.1" > /etc/resolv.conf
      echo "[OK] Primary DNS node finalized"
    EOT
    ]
  }
}

# Configure local DNS records on primary node (non-SDN)
resource "null_resource" "configure_local_dns" {
  depends_on = [null_resource.finalize_primary_dns]

  count = !var.is_sdn_network && var.dns_zone != "" ? 1 : 0

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/crypto/lab-deploy")
    host        = local.primary_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      set -e
      export PATH="/usr/local/bin:$PATH"

      echo "[+] Configuring local DNS zone: ${var.dns_zone}"

      # Pi-hole v6 uses pihole-FTL --config dns.hosts with JSON array
      # Format: ["IP hostname hostname.domain", ...]
      DNS_HOSTS='[${join(",", [for hostname, node in local.nodes_map : "\"${node.ip_bare} ${hostname} ${hostname}.${var.dns_zone}\""])}]'

      echo "[+] Adding DNS entries:"
%{for hostname, node in local.nodes_map~}
      echo "  - ${hostname}.${var.dns_zone} -> ${node.ip_bare}"
%{endfor~}

      # Configure DNS hosts
      pihole-FTL --config dns.hosts "$DNS_HOSTS"

      # Configure DNS domain
      pihole-FTL --config dns.domain.name '${var.dns_zone}'

      echo "[OK] Local DNS configuration complete"
    EOT
    ]
  }
}

# ============================================================================
# SDN Network Provisioning (via pct exec)
# ============================================================================

# SDN provisioning via pct exec (only for SDN networks)
resource "null_resource" "sdn_provision" {
  for_each   = var.is_sdn_network ? local.nodes_map : {}
  depends_on = [proxmox_lxc.dns]

  triggers = {
    vmid = proxmox_lxc.dns[each.key].vmid
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for container to be fully started and running
      echo "[+] Waiting for container ${proxmox_lxc.dns[each.key].vmid} to be running..."
      for i in $(seq 1 30); do
        STATUS=$(ssh -i /crypto/lab-deploy -o StrictHostKeyChecking=no root@${each.value.ssh_host} \
          "pct status ${proxmox_lxc.dns[each.key].vmid} 2>/dev/null | grep -oE 'running|stopped'" || echo "unknown")
        if [ "$STATUS" = "running" ]; then
          echo "[+] Container ${proxmox_lxc.dns[each.key].vmid} is running"
          break
        fi
        echo "  Waiting... (attempt $i/30, status: $STATUS)"
        if [ "$STATUS" = "stopped" ]; then
          echo "[+] Starting container ${proxmox_lxc.dns[each.key].vmid}..."
          ssh -i /crypto/lab-deploy -o StrictHostKeyChecking=no root@${each.value.ssh_host} \
            "pct start ${proxmox_lxc.dns[each.key].vmid}" || true
        fi
        sleep 5
      done

      # Copy unbound config to Proxmox host first
      cat > /tmp/unbound-${each.key}.conf <<'UNBOUNDCONF'
${local.unbound_conf}
UNBOUNDCONF

      scp -i /crypto/lab-deploy -o StrictHostKeyChecking=no /tmp/unbound-${each.key}.conf root@${each.value.ssh_host}:/tmp/unbound-${each.key}.conf

      ssh -i /crypto/lab-deploy -o StrictHostKeyChecking=no -o ConnectTimeout=30 root@${each.value.ssh_host} \
        "pct push ${proxmox_lxc.dns[each.key].vmid} /tmp/unbound-${each.key}.conf /tmp/pi-hole-unbound.conf"

      # Create install script on Proxmox host
      cat > /tmp/install-pihole-${each.key}.sh <<'INSTALLSCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:$PATH"

# Use public DNS for package installation
cp /etc/resolv.conf /etc/resolv.conf.bak || true
echo "nameserver 1.1.1.1" > /etc/resolv.conf

echo "[+] Updating package lists..."
apt-get update

echo "[+] Installing dependencies..."
apt-get install -y curl wget apt-transport-https dnsutils jq unbound sqlite3

echo "[+] Configuring Unbound for DNS-over-TLS..."
cat > /etc/unbound/unbound.conf <<'UNBOUNDMAIN'
include: "/etc/unbound/unbound.conf.d/pi-hole.conf"
UNBOUNDMAIN

mv /tmp/pi-hole-unbound.conf /etc/unbound/unbound.conf.d/pi-hole.conf

systemctl enable unbound
systemctl restart unbound

sleep 2
echo "[+] Testing Unbound..."
dig @127.0.0.1 -p 5335 google.com +short || echo "[!] Unbound test failed, continuing..."

echo "[+] Installing Pi-hole..."
mkdir -p /etc/pihole
cat > /etc/pihole/setupVars.conf <<'SETUPVARS'
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=0.0.0.0/24
IPV6_ADDRESS=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
DNSMASQ_LISTENING=single
PIHOLE_DNS_1=127.0.0.1#5335
SETUPVARS

curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended

echo "[+] Configuring Pi-hole v6..."
pihole-FTL --config dns.upstreams '["127.0.0.1#5335"]'
pihole-FTL --config dns.listeningMode ALL
pihole-FTL --config webserver.api.password '${var.admin_password}'

systemctl restart pihole-FTL

echo "[OK] Pi-hole + Unbound installation complete"
INSTALLSCRIPT

      scp -i /crypto/lab-deploy -o StrictHostKeyChecking=no /tmp/install-pihole-${each.key}.sh root@${each.value.ssh_host}:/tmp/install-pihole-${each.key}.sh

      ssh -i /crypto/lab-deploy -o StrictHostKeyChecking=no -o ConnectTimeout=300 root@${each.value.ssh_host} \
        "pct push ${proxmox_lxc.dns[each.key].vmid} /tmp/install-pihole-${each.key}.sh /tmp/install-pihole.sh && pct exec ${proxmox_lxc.dns[each.key].vmid} -- bash /tmp/install-pihole.sh"

      echo "[OK] Pi-hole installed on ${each.key}"
    EOT
  }
}

# Nebula-Sync setup on primary SDN node - syncs TO replica nodes
resource "null_resource" "sdn_nebula_sync_setup" {
  depends_on = [null_resource.sdn_provision]

  # Only run if there's more than one node (need replicas to sync to)
  count = var.is_sdn_network && length(var.nodes) > 1 ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      # Build replica list (all nodes except first/primary)
      REPLICAS="${join(",", [for idx, node in var.nodes : "http://${regex("^([^/]+)", node.ip)[0]}|${var.admin_password}" if idx > 0])}"

      cat > /tmp/nebula-sync-install.sh <<NSSCRIPT
#!/bin/bash
set -e
export PATH="/usr/local/bin:\$PATH"

echo "nameserver 1.1.1.1" > /etc/resolv.conf

echo "[+] Installing Nebula-Sync on primary node..."

# Install curl if not available
apt-get update -qq && apt-get install -y -qq curl

# Download and extract Nebula-Sync binary
cd /tmp
curl -sSL -o nebula-sync.tar.gz \
  https://github.com/lovelaze/nebula-sync/releases/download/v0.11.1/nebula-sync_0.11.1_linux_amd64.tar.gz
tar -xzf nebula-sync.tar.gz
mv nebula-sync /usr/local/bin/nebula-sync
chmod +x /usr/local/bin/nebula-sync
rm -f nebula-sync.tar.gz

# Create environment file with secrets (restricted permissions)
mkdir -p /etc/nebula-sync
cat > /etc/nebula-sync/env <<ENVEOF
PRIMARY=http://127.0.0.1|${var.admin_password}
REPLICAS=$REPLICAS
FULL_SYNC=true
RUN_GRAVITY=true
HTTP_ENABLED=false
ENVEOF
chmod 600 /etc/nebula-sync/env

# Create systemd service for Nebula-Sync
cat > /etc/systemd/system/nebula-sync.service <<'SERVICEEOF'
[Unit]
Description=Nebula-Sync Pi-hole synchronization
After=network.target pihole-FTL.service

[Service]
Type=oneshot
EnvironmentFile=/etc/nebula-sync/env
ExecStart=/usr/local/bin/nebula-sync run
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Create systemd timer to run every 5 minutes
cat > /etc/systemd/system/nebula-sync.timer <<'TIMEREOF'
[Unit]
Description=Run Nebula-Sync every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
TIMEREOF

# Enable and start the timer
systemctl daemon-reload
systemctl enable nebula-sync.timer
systemctl start nebula-sync.timer

# Run initial sync
echo "[+] Running initial Nebula-Sync..."
systemctl start nebula-sync.service || echo "[!] Initial sync may have failed, will retry on timer"

echo "[OK] Nebula-Sync configured on primary node"

# Switch back to local DNS
echo "nameserver 127.0.0.1" > /etc/resolv.conf
NSSCRIPT

      scp -i /crypto/lab-deploy -o StrictHostKeyChecking=no /tmp/nebula-sync-install.sh root@${local.primary_ssh_host}:/tmp/nebula-sync-install.sh

      ssh -i /crypto/lab-deploy -o StrictHostKeyChecking=no root@${local.primary_ssh_host} \
        "pct push ${var.vmid_start} /tmp/nebula-sync-install.sh /tmp/nebula-sync-install.sh && pct exec ${var.vmid_start} -- bash /tmp/nebula-sync-install.sh"
    EOT
  }
}

# Finalize primary SDN node
resource "null_resource" "sdn_finalize_primary" {
  depends_on = [null_resource.sdn_nebula_sync_setup, null_resource.sdn_provision]

  count = var.is_sdn_network ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i /crypto/lab-deploy -o StrictHostKeyChecking=no root@${local.primary_ssh_host} \
        "pct exec ${var.vmid_start} -- bash -c 'echo nameserver 127.0.0.1 > /etc/resolv.conf'"
    EOT
  }
}

# Configure local DNS records on primary SDN node
resource "null_resource" "sdn_configure_local_dns" {
  depends_on = [null_resource.sdn_finalize_primary]

  count = var.is_sdn_network && var.dns_zone != "" ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      cat > /tmp/dns-config-sdn.sh <<'DNSSCRIPT'
#!/bin/bash
set -e
export PATH="/usr/local/bin:/opt/pihole:$PATH"

echo "[+] Configuring local DNS zone: ${var.dns_zone}"

# Wait for Pi-hole to be ready
for i in $(seq 1 30); do
  if command -v pihole-FTL &>/dev/null || [ -x /usr/bin/pihole-FTL ]; then
    break
  fi
  echo "  Waiting for Pi-hole installation... (attempt $i/30)"
  sleep 5
done

# Verify pihole-FTL exists
if ! command -v pihole-FTL &>/dev/null && [ ! -x /usr/bin/pihole-FTL ]; then
  echo "[!] ERROR: pihole-FTL not found. Pi-hole may not be installed."
  exit 1
fi

# Pi-hole v6 uses pihole-FTL --config dns.hosts with JSON array
DNS_HOSTS='[${join(",", [for hostname, node in local.nodes_map : "\"${node.ip_bare} ${hostname} ${hostname}.${var.dns_zone}\""])}]'

echo "[+] Adding DNS entries:"
%{for hostname, node in local.nodes_map~}
echo "  - ${hostname}.${var.dns_zone} -> ${node.ip_bare}"
%{endfor~}

# Configure DNS hosts
/usr/bin/pihole-FTL --config dns.hosts "$DNS_HOSTS"

# Configure DNS domain
/usr/bin/pihole-FTL --config dns.domain.name '${var.dns_zone}'

echo "[OK] Local DNS configuration complete"
DNSSCRIPT

      scp -i /crypto/lab-deploy -o StrictHostKeyChecking=no /tmp/dns-config-sdn.sh root@${local.primary_ssh_host}:/tmp/dns-config-sdn.sh

      ssh -i /crypto/lab-deploy -o StrictHostKeyChecking=no root@${local.primary_ssh_host} \
        "pct push ${var.vmid_start} /tmp/dns-config-sdn.sh /tmp/dns-config.sh && pct exec ${var.vmid_start} -- bash /tmp/dns-config.sh"
    EOT
  }
}
