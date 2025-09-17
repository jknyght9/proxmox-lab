locals {
  external_eth0_ipv4 = regex("^([^/]+)", var.external_eth0_ipv4_cidr)[0] # strip CIDR mask
  proxmox_api_host   = regex("^https?://([^:/]+)", var.proxmox_api_url)[0]
}

resource "proxmox_lxc" "pihole-internal" {
  target_node       = var.proxmox_target_node
  vmid              = var.vmid_internal
  hostname          = "pihole-internal"
  clone             = "pihole-template"
  full              = true 
  unprivileged      = false
  ostype            = "debian"
  cores             = 2
  memory            = 1024
  swap              = 1024
  start             = true
  onboot            = true
  rootfs {
    storage         = "local-lvm"
    size            = "4G"
  }
  network {
    name            = "eth0"
    bridge          = "labnet"
    ip              = "172.16.0.3/24"
    gw              = "172.16.0.1"
  }
  features {
    nesting         = true
  }

  provisioner "remote-exec" {
    inline = [
      "pct start ${var.vmid_internal} || true"
    ]

    connection {
      type          = "ssh"
      user          = "root"
      private_key   = file("/crypto/lab-deploy")
      host          = local.proxmox_api_host
    }
  }

  tags              = "terraform,infra,lxc"
}

resource "proxmox_lxc" "pihole-external" {
  target_node       = var.proxmox_target_node
  vmid              = var.vmid_external
  hostname          = "pihole-external"
  clone             = "pihole-template"
  full              = true 
  unprivileged      = false
  ostype            = "debian"
  cores             = 2
  memory            = 1024
  swap              = 1024
  start             = true
  onboot            = true
  rootfs {
    storage         = "local-lvm"
    size            = "4G"
  }
  network {
    name            = "eth0"
    bridge          = var.external_eth0_vmbr
    ip              = var.external_eth0_ipv4_cidr
    gw              = var.external_eth0_gw
  }
  features {
    nesting         = true
  }

  provisioner "remote-exec" {
    inline = [
      "pct start ${var.vmid_external} || true"
    ]

    connection {
      type          = "ssh"
      user          = "root"
      private_key   = file("/crypto/lab-deploy")
      host          = local.proxmox_api_host
    }
  }

  provisioner "remote-exec" {
    inline = [
      "pihole-FTL --config dhcp.active false",
      "systemctl restart pihole-FTL"
    ]
    connection {
      type            = "ssh"
      user            = "root"
      private_key     = file("/crypto/lab-deploy")
      host            = local.external_eth0_ipv4
    }
  }
  tags              = "terraform,infra,lxc"
}
