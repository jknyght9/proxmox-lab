# =============================================================================
# Pulse agents — Nomad VMs (Phase 2)
#
# The Pulse agent is a binary (no container image) installed via the official
# installer as a systemd unit; it reports host + Docker-container metrics. Each
# Docker host needs its OWN agent token (a shared token => "already in use by
# agent" and only one host reports).
#
# This runs the installer on every Nomad VM with a per-node token that is minted
# once via the Pulse API and cached in Vault (secret/pulse-agents/<node>) so
# re-runs reuse it (idempotent — no orphaned/duplicate tokens on every apply).
#
# TrueNAS (SCALE, agent-based) is a documented manual step — see docs/services/
# pulse.md — because it's a managed appliance, not Terraform-driven here.
# =============================================================================

resource "null_resource" "pulse_agent" {
  for_each = var.deploy_pulse ? var.nomad_node_ips : {}

  # pulse_config sets up the Pulse API (admin/SSO/PVE) before agents enroll.
  depends_on = [null_resource.pulse_config]

  triggers = {
    node   = each.key
    script = filesha256("${path.module}/templates/pulse-agent-install.sh.tpl")
  }

  connection {
    type        = "ssh"
    host        = each.value
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/pulse-agent-install.sh.tpl", {
      vault_address = var.vault_address
      vault_token   = var.vault_token
      node          = each.key
      pulse_api     = "http://${local.nomad01_ip}:7655"
      pulse_url     = "https://pulse.${var.dns_postfix}"
    })
    destination = "/tmp/pulse-agent-install.sh"
  }

  provisioner "remote-exec" {
    # Clean up via an EXIT trap, NOT a trailing `rm` — a trailing rm returns 0
    # and masks a non-zero exit from the installer (e.g. an agent download
    # failure), so a failed install would be reported as a successful apply.
    # With `set -e` + trap, the failure propagates and fails the apply, while
    # the temp file is still removed. (POSIX-safe: no `pipefail`, since
    # remote-exec may run under dash.)
    inline = [
      "set -e",
      "trap 'rm -f /tmp/pulse-agent-install.sh' EXIT",
      "chmod +x /tmp/pulse-agent-install.sh",
      "sudo bash /tmp/pulse-agent-install.sh",
    ]
  }
}
