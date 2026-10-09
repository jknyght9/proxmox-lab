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

# SSO access control + role mapping, derived from the site's group lists.
# allowedGroups = the union (users outside these groups are denied); the role
# map grants admin to admin-groups and viewer to viewer-groups. Both empty =>
# "[]" / "{}" => no restriction and no elevation (safe default).
locals {
  # Per-app overrides win when set; otherwise fall back to the canonical lab
  # role groups so Pulse shares the same two groups as every other SSO app by
  # default (admins -> "admin", users -> "viewer").
  pulse_admin_groups  = length(var.pulse_sso_admin_groups) > 0 ? var.pulse_sso_admin_groups : var.sso_admin_groups
  pulse_viewer_groups = length(var.pulse_sso_viewer_groups) > 0 ? var.pulse_sso_viewer_groups : var.sso_user_groups

  pulse_sso_allowed_groups = concat(local.pulse_admin_groups, local.pulse_viewer_groups)
  pulse_sso_group_roles = merge(
    { for g in local.pulse_admin_groups : g => "admin" },
    { for g in local.pulse_viewer_groups : g => "viewer" },
  )
}

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
    # re-run when the SSO access/role config changes
    sso_groups = jsonencode([local.pulse_sso_allowed_groups, local.pulse_sso_group_roles])
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
      vault_address       = var.vault_address
      vault_token         = var.vault_token
      pve_host            = var.pulse_pve_host
      dns_postfix         = var.dns_postfix
      allowed_groups_json = jsonencode(local.pulse_sso_allowed_groups)
      group_role_map_json = jsonencode(local.pulse_sso_group_roles)
    })
    destination = "/tmp/pulse-config.sh"
  }

  provisioner "remote-exec" {
    # Clean up via an EXIT trap, NOT a trailing `rm` — a trailing rm returns 0
    # and masks a non-zero exit from pulse-config.sh, so a failed reconcile
    # (e.g. a Pulse API 400) would be reported as a successful apply. With
    # `set -e` + trap, the script's failure propagates and fails the apply,
    # while the temp file is still removed. (POSIX-safe: no `pipefail`, since
    # remote-exec may run under dash.)
    inline = [
      "set -e",
      "trap 'rm -f /tmp/pulse-config.sh' EXIT",
      "chmod +x /tmp/pulse-config.sh",
      "bash /tmp/pulse-config.sh",
    ]
  }
}
