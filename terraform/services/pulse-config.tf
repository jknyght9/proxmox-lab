# =============================================================================
# Pulse post-deploy configuration (via Pulse REST API)
#
# Pulse 6.4.5 won't take OIDC from env vars and stores monitored targets +
# SSO providers encrypted in /data, configured through its API. This resource
# logs into Pulse (local admin from secret/pulse) and idempotently
# create-or-updates:
#   1. the Authentik OIDC SSO provider (caBundle -> the root CA the job mounts), and
#   2. the Proxmox cluster (var.pulse_pve_host; one member auto-discovers the rest).
# so a fresh deploy comes up with SSO + PVE monitoring already wired — no manual
# UI step. Mirrors the authentik-apps.tf pattern (ssh to nomad01, templatefile
# script, secrets read from Vault at runtime).
#
# TrueNAS + the Nomad VMs are agent-based (minted agent tokens) — Phase 2, not
# handled here.
# =============================================================================

resource "null_resource" "pulse_config" {
  count = var.deploy_pulse ? 1 : 0

  depends_on = [
    nomad_job.pulse,
    vault_kv_secret_v2.pulse_oidc,
    null_resource.authentik_apps,
  ]

  triggers = {
    pve_host    = var.pulse_pve_host
    dns_postfix = var.dns_postfix
    # re-run when the reconcile script itself changes
    script = filesha256("${path.module}/templates/pulse-config.sh.tpl")
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/pulse-config.sh.tpl", {
      vault_address = var.vault_address
      vault_token   = var.vault_token
      pve_host      = var.pulse_pve_host
      dns_postfix   = var.dns_postfix
    })
    destination = "/tmp/pulse-config.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/pulse-config.sh",
      "bash /tmp/pulse-config.sh",
      "rm -f /tmp/pulse-config.sh",
    ]
  }
}
