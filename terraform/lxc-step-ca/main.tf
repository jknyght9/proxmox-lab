locals {
  eth0_ipv4       = regex("^([^/]+)", var.eth0_ipv4_cidr)[0] # strip CIDR mask
  dns_primary_ipv4 = var.dns_primary_ipv4
}

resource "proxmox_lxc" "step-ca" {
  target_node       = var.proxmox_target_node
  vmid              = var.vmid
  hostname          = "step-ca"
  ostemplate        = var.ostemplate
  password          = var.root_password
  ssh_public_keys   = file(var.ssh_admin_public_key_file)  # Admin key for container access
  unprivileged      = true
  # Use bootstrap DNS for initial provisioning (avoids inheriting Tailscale/host DNS)
  nameserver        = var.bootstrap_dns

  cores             = 2
  memory            = 2048
  swap              = 2048
  start             = true
  onboot            = true

  rootfs {
    storage         = "local-lvm"
    size            = "8G"
  }

  network {
    name    = "eth0"
    bridge  = var.eth0_vmbr
    ip      = var.eth0_ipv4_cidr
    gw      = var.eth0_gateway
  }

  # Optional second NIC for ACME validation to reach Proxmox management network
  dynamic "network" {
    for_each = var.eth1_enabled ? [1] : []
    content {
      name   = "eth1"
      bridge = var.eth1_vmbr
      ip     = var.eth1_ipv4_cidr
    }
  }

  features {
    nesting         = true
  }

  tags              = "terraform,ca,lxc"

  # Install step-ca and initialize with correct DNS names
  provisioner "remote-exec" {
    inline = [<<-EOT
      bash -c "set -euxo pipefail
        # Use public DNS for package installation (internal DNS may not be ready)
        cp /etc/resolv.conf /etc/resolv.conf.bak
        echo 'nameserver ${var.bootstrap_dns}' > /etc/resolv.conf

        apt-get update && apt-get install -y --no-install-recommends curl gpg ca-certificates jq
        curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg -o /etc/apt/trusted.gpg.d/smallstep.asc
        echo \"deb [signed-by=/etc/apt/trusted.gpg.d/smallstep.asc] https://packages.smallstep.com/stable/debian debs main\" | tee /etc/apt/sources.list.d/smallstep.list
        apt-get update && apt-get -y install step-cli step-ca

        # Initialize step-ca with correct DNS names for this deployment
        mkdir -p /etc/step-ca/secrets
        openssl rand -base64 32 > /etc/step-ca/secrets/password_file
        chmod 600 /etc/step-ca/secrets/password_file

        step ca init \\
          --deployment-type standalone \\
          --name proxmox-lab \\
          --address ':443' \\
          --dns 'ca.${var.dns_postfix}' \\
          --dns 'step-ca.${var.dns_postfix}' \\
          --dns '${local.eth0_ipv4}' \\
          --dns 'localhost' \\
          --provisioner 'admin@${var.dns_postfix}' \\
          --password-file /etc/step-ca/secrets/password_file \\
          --acme

        # Update ACME configuration to allow longer duration certs (90 days)
        tmp=\$(mktemp)
        jq '.authority.provisioners |= map(
          if .type==\"ACME\" and .name==\"acme\" then
            .claims = (.claims // {}) + {defaultTLSCertDuration:\"2160h\", maxTLSCertDuration:\"2160h\"}
          else . end
        )' /etc/step-ca/config/ca.json > \"\$tmp\" && mv \"\$tmp\" /etc/step-ca/config/ca.json

        # Create systemd service
        cat <<EOF >/etc/systemd/system/step-ca.service
[Unit]
Description=Step Certificate Authority
After=network.target

[Service]
ExecStart=/usr/bin/step-ca /etc/step-ca/config/ca.json --password-file /etc/step-ca/secrets/password_file
WorkingDirectory=/etc/step-ca
User=root
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now step-ca

        # Switch to internal DNS now that setup is complete
        echo 'nameserver ${local.dns_primary_ipv4}' > /etc/resolv.conf"
    EOT
    ]
  }

  connection {
    type            = "ssh"
    user            = "root"
    private_key     = file(var.ssh_admin_private_key_file)  # Admin key for container access
    host            = local.eth0_ipv4
  }
}
