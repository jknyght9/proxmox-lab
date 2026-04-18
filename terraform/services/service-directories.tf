# =============================================================================
# GlusterFS Service Directories — created before Nomad jobs deploy
# Replaces: mkdir calls scattered across deploy scripts
# =============================================================================

resource "null_resource" "service_directories" {
  triggers = {
    services = join(",", compact([
      "vault",
      "vault-tls",
      "certs",
      var.deploy_traefik    ? "traefik,traefik/config,traefik/tls" : "",
      var.deploy_authentik  ? "authentik,authentik/postgres,authentik/data,authentik/data/media,authentik/branding" : "",
      var.deploy_samba_dc   ? "" : "",  # samba uses /opt/samba-dc01 on host, not gluster
      var.deploy_uptime_kuma ? "uptime-kuma" : "",
    ]))
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      echo '[+] Creating GlusterFS service directories...'
      GLUSTER="/srv/gluster/nomad-data"

      # Core (always) — Vault container runs as root but needs write access
      sudo mkdir -p $GLUSTER/vault $GLUSTER/vault-tls $GLUSTER/certs
      sudo chmod 777 $GLUSTER/vault $GLUSTER/vault-tls

      %{if var.deploy_traefik}
      sudo mkdir -p $GLUSTER/traefik/config $GLUSTER/traefik/tls
      %{endif}

      %{if var.deploy_authentik}
      sudo mkdir -p $GLUSTER/authentik/{postgres,data/media,branding}
      # Placeholder branding files (prevents Docker bind-mount creating dirs)
      [ -f $GLUSTER/authentik/branding/background.png ] || sudo touch $GLUSTER/authentik/branding/background.png
      [ -f $GLUSTER/authentik/branding/logo.svg ] || sudo touch $GLUSTER/authentik/branding/logo.svg
      sudo chown -R 1000:1000 $GLUSTER/authentik/data
      %{endif}

      %{if var.deploy_uptime_kuma}
      sudo mkdir -p $GLUSTER/uptime-kuma
      %{endif}

      echo '[+] Service directories created'
      EOT
    ]
  }
}

# Samba DC uses local storage on each node, not GlusterFS
resource "null_resource" "samba_directories" {
  for_each = var.deploy_samba_dc ? {
    dc01 = { node = "nomad01", ip = var.nomad_node_ips["nomad01"], dir = "/opt/samba-dc01" }
    dc02 = length(var.nomad_node_ips) > 1 ? { node = "nomad02", ip = var.nomad_node_ips["nomad02"], dir = "/opt/samba-dc02" } : null
  } : {}

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${each.value.dir}/{samba,samba/private,krb5,smb.conf}",
      "echo '[+] Samba DC directory prepared at ${each.value.dir} on ${each.value.node}'",
    ]
  }
}
