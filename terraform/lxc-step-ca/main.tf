locals {
  eth0_ipv4 = regex("^([^/]+)", var.eth0_ipv4_cidr)[0] # strip CIDR mask
}

resource "proxmox_lxc" "step-ca" {
  target_node       = "pve"
  vmid              = var.vmid
  hostname          = "step-ca"
  ostemplate        = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
  password          = var.root_password 
  ssh_public_keys   = file("/crypto/lab-deploy.pub")
  unprivileged      = true

  cores             = 2
  memory            = 2048
  swap              = 2048
  start             = true 

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

  features {
    nesting         = true
  }

  tags              = "terraform,infra,lxc"

  # Upload secrets and certificates after creation
  provisioner "file" {
    source          = "${path.module}/step-ca"
    destination     = "/root/step-ca"
  }

  # Install step-ca and configure it
  provisioner "remote-exec" {
    inline = [<<-EOT
      bash -c "set -euxo pipefail
        apt-get update && apt-get install -y --no-install-recommends curl gpg ca-certificates
        curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg -o /etc/apt/trusted.gpg.d/smallstep.asc
        echo \"deb [signed-by=/etc/apt/trusted.gpg.d/smallstep.asc] https://packages.smallstep.com/stable/debian debs main\" | tee /etc/apt/sources.list.d/smallstep.list
        apt-get update && apt-get -y install step-cli step-ca
        mkdir -p /etc/step-ca && cp -r /root/step-ca/* /etc/step-ca/
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
        systemctl enable --now step-ca"
    EOT
    ]
  }

  connection {
    type            = "ssh"
    user            = "root"
    private_key     = file("/crypto/lab-deploy")
    host            = local.eth0_ipv4
  }
}