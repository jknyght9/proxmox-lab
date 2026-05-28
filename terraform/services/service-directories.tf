# =============================================================================
# Service Directories — created before Nomad jobs deploy
# Replaces: mkdir calls scattered across deploy scripts
#
# Post-gluster-decommission this only handles:
#   - Samba DCs (local-disk per Nomad VM, not migrated to CSI/NFS)
#   - LAM config bootstrap (NFS share is pre-created in Phase 0, but
#     we still need to seed it from the container image's defaults)
#
# All other services either get their state from the cluster_state NAS
# (Phase 0 created the datasets + shares) or from Vault PKI / Nomad
# template stanzas at runtime. The old gluster mkdir was a no-op for
# everything except Samba and LAM-bootstrap after Phase 2 landed; this
# file now reflects that.
# =============================================================================

# LAM config bootstrap — extract defaults from container image once.
# The lam-config CSI volume's NFS share (Phase 0) starts empty; LAM's
# entrypoint will regenerate lam.conf, but image-shipped helpers like
# apache.conf live in /etc/ldap-account-manager and need to be seeded.
# We mount the NFS share temporarily on nomad01, dump the container's
# defaults into it, unmount.
resource "null_resource" "lam_bootstrap" {
  count = var.deploy_lam ? 1 : 0

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
      MNT=/tmp/nfs-lam-bootstrap
      sudo mkdir -p $MNT
      sudo mount -t nfs -o nfsvers=4.1 ${local.cluster_state_nas.address}:/mnt/${local.cluster_state_dataset_root}/lam-config $MNT
      if [ -f $MNT/config.cfg ]; then
        echo '[+] LAM config already seeded, skipping bootstrap'
        sudo umount $MNT && sudo rmdir $MNT
        exit 0
      fi
      echo '[+] Bootstrapping LAM default config from container into NFS share...'
      sudo docker rm -f lam-bootstrap 2>/dev/null || true
      sudo docker pull ghcr.io/ldapaccountmanager/lam:9.6.RC1
      sudo docker create --name lam-bootstrap ghcr.io/ldapaccountmanager/lam:9.6.RC1
      sudo docker cp lam-bootstrap:/etc/ldap-account-manager/. $MNT/
      sudo docker rm lam-bootstrap
      sudo chmod -R 777 $MNT
      sudo umount $MNT && sudo rmdir $MNT
      echo '[+] LAM config bootstrapped'
      EOT
    ]
  }
}

# Samba DC uses local storage on each node — never on shared storage
# (POSIX-ACL semantics, AD replication handles redundancy). One mkdir
# per DC's host VM.
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
