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
      var.deploy_traefik ? "traefik,traefik/config,traefik/tls" : "",
      var.deploy_authentik ? "authentik,authentik/postgres,authentik/data,authentik/data/media" : "",
      var.deploy_samba_ad ? "" : "", # samba uses /opt/samba-dc01 on host, not gluster
      var.deploy_uptime_kuma ? "uptime-kuma" : "",
      var.deploy_lam ? "lam,lam/config,lam/session" : "",
      var.deploy_netbox ? "netbox,netbox/postgres,netbox/redis,netbox/data/media" : "",
      "docs,docs/site",
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
      sudo mkdir -p $GLUSTER/authentik/postgres $GLUSTER/authentik/data/media
      sudo chown -R 1000:1000 $GLUSTER/authentik/data
      # Branding disabled — uncomment to enable custom branding
      # sudo mkdir -p $GLUSTER/authentik/branding
      # [ -f $GLUSTER/authentik/branding/background.png ] || sudo touch $GLUSTER/authentik/branding/background.png
      # [ -f $GLUSTER/authentik/branding/logo.svg ] || sudo touch $GLUSTER/authentik/branding/logo.svg
      %{endif}

      %{if var.deploy_uptime_kuma}
      sudo mkdir -p $GLUSTER/uptime-kuma
      %{endif}

      %{if var.deploy_lam}
      sudo mkdir -p $GLUSTER/lam/config $GLUSTER/lam/session
      %{endif}

      %{if var.deploy_netbox}
      sudo mkdir -p $GLUSTER/netbox/postgres $GLUSTER/netbox/redis $GLUSTER/netbox/data/media
      %{endif}

      sudo mkdir -p $GLUSTER/docs/site

      echo '[+] Service directories created'
      EOT
    ]
  }
}

# LAM config bootstrap — extract defaults from container image
resource "null_resource" "lam_bootstrap" {
  count      = var.deploy_lam ? 1 : 0
  depends_on = [null_resource.service_directories]

  triggers = {
    deploy_lam = var.deploy_lam
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
      set -e
      GLUSTER="/srv/gluster/nomad-data"
      if [ -f $GLUSTER/lam/config/config.cfg ]; then
        echo '[+] LAM config already exists, skipping bootstrap'
        exit 0
      fi
      echo '[+] Bootstrapping LAM default config from container...'
      sudo docker rm -f lam-bootstrap 2>/dev/null || true
      sudo docker pull ghcr.io/ldapaccountmanager/lam:9.5.2
      sudo docker create --name lam-bootstrap ghcr.io/ldapaccountmanager/lam:9.5.2
      sudo docker cp lam-bootstrap:/etc/ldap-account-manager/. $GLUSTER/lam/config/
      sudo docker rm lam-bootstrap
      sudo chmod -R 777 $GLUSTER/lam
      echo '[+] LAM config bootstrapped'
      ls -la $GLUSTER/lam/config/
      EOT
    ]
  }
}

# Samba DC uses local storage on each node, not GlusterFS
resource "null_resource" "samba_directories" {
  for_each = var.deploy_samba_ad ? {
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
      "sudo mkdir -p ${each.value.dir}/samba/private ${each.value.dir}/krb5",
      "[ -f ${each.value.dir}/smb.conf ] || sudo touch ${each.value.dir}/smb.conf",
      "echo '[+] Samba DC directory prepared at ${each.value.dir} on ${each.value.node}'",
    ]
  }
}
