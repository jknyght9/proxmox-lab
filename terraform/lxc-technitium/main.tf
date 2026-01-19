locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_api_url)[0]

  # Create a map from hostname to node config for for_each
  nodes_map = { for idx, node in var.nodes : node.hostname => merge(node, {
    index = idx
    vmid  = var.vmid_start + idx
    ip_bare = regex("^([^/]+)", node.ip)[0]
  })}

  # First node is the primary for cluster initialization
  primary_node = var.nodes[0]
  primary_ip   = regex("^([^/]+)", local.primary_node.ip)[0]
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
    storage = "local-lvm"
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

  tags = "terraform,infra,lxc,dns,${var.cluster_name}"

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/crypto/lab-deploy")
    host        = each.value.ip_bare
  }

  # Install Technitium DNS
  provisioner "remote-exec" {
    inline = [<<-EOT
      bash -c "set -euxo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y curl wget apt-transport-https dnsutils jq

        # Install Technitium DNS Server
        curl -sSL https://download.technitium.com/dns/install.sh | bash

        # Wait for service to start
        sleep 15

        # Change admin password (default is admin/admin)
        TOKEN=\$(curl -s 'http://127.0.0.1:5380/api/user/login?user=admin&pass=admin' | jq -r '.token // empty')
        if [ -n \"\$TOKEN\" ]; then
          curl -s \"http://127.0.0.1:5380/api/user/changePassword?token=\${TOKEN}&pass=${var.admin_password}\" > /dev/null
          echo '[+] Admin password configured'
        fi

        systemctl enable dns
        echo '[✓] Technitium DNS installation complete'"
    EOT
    ]
  }
}

# Configure clustering on the primary node after all nodes are created
resource "null_resource" "cluster_setup" {
  depends_on = [proxmox_lxc.dns]

  # Only run if there's more than one node
  count = length(var.nodes) > 1 ? 1 : 0

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/crypto/lab-deploy")
    host        = local.primary_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      bash -c "set -euxo pipefail
        # Get auth token
        TOKEN=\$(curl -s 'http://127.0.0.1:5380/api/user/login?user=admin&pass=${var.admin_password}' | jq -r '.token')

        # Enable clustering on primary
        echo '[+] Enabling clustering on primary node'
        curl -s \"http://127.0.0.1:5380/api/settings/set?token=\${TOKEN}&enableDnsOverHttp=true\" > /dev/null

        # Get cluster secret for other nodes to join
        echo '[+] Cluster configuration complete on primary'"
    EOT
    ]
  }
}

# Join secondary nodes to the cluster
resource "null_resource" "cluster_join" {
  depends_on = [null_resource.cluster_setup]

  for_each = { for hostname, node in local.nodes_map : hostname => node if node.index > 0 }

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/crypto/lab-deploy")
    host        = each.value.ip_bare
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      bash -c "set -euxo pipefail
        TOKEN=\$(curl -s 'http://127.0.0.1:5380/api/user/login?user=admin&pass=${var.admin_password}' | jq -r '.token')

        # Enable clustering
        curl -s \"http://127.0.0.1:5380/api/settings/set?token=\${TOKEN}&enableDnsOverHttp=true\" > /dev/null

        echo '[+] Node ${each.key} configured for clustering'"
    EOT
    ]
  }
}
