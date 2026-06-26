# =============================================================================
# Samba AD Groups — declarative group creation
#
# Define groups via the `ad_groups` variable as a name → description map.
# Groups are created idempotently via `samba-tool group add` on DC01.
#
# Lab-specific group definitions live in a separate lab-extensions overlay
# (see lab-ad-groups.auto.tfvars or lab-ad-groups.auto.tfvars.example).
# This file holds the capability; the overlay holds the content.
# =============================================================================

variable "ad_groups" {
  description = "AD security groups to create as a name → description map. Typically populated by a lab-extensions overlay tfvars file."
  type        = map(string)
  default     = {}
}

resource "null_resource" "ad_groups" {
  count      = var.deploy_samba_ad && length(var.ad_groups) > 0 ? 1 : 0
  depends_on = [null_resource.ad_service_accounts]

  triggers = {
    groups_hash = sha256(jsonencode(var.ad_groups))
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
      echo '[+] Locating Samba AD container...'
      CONTAINER=""
      for i in $(seq 1 30); do
        CONTAINER=$(docker ps --format '{{.ID}} {{.Names}}' | grep 'samba-ad' | head -1 | awk '{print $1}')
        if [ -n "$CONTAINER" ] && docker exec "$CONTAINER" samba-tool domain level show >/dev/null 2>&1; then
          break
        fi
        sleep 5
        CONTAINER=""
      done

      if [ -z "$CONTAINER" ]; then
        echo '[!] Samba AD container not found'
        exit 1
      fi

      echo '[+] Creating AD groups (idempotent)...'

      %{for name, description in var.ad_groups~}
      if ! docker exec $CONTAINER samba-tool group show '${name}' >/dev/null 2>&1; then
        echo '    creating: ${name}'
        docker exec $CONTAINER samba-tool group add '${name}' \
          --description='${description}'
      else
        echo '    exists:   ${name}'
      fi
      %{endfor~}

      echo '[+] AD groups configured (${length(var.ad_groups)} total)'
      EOT
    ]
  }
}
