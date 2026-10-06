# =============================================================================
# DNS Records — managed via Pi-hole FTL CLI (Pi-hole v6.6+)
#
# NOTE: The ryanwholey/pihole Terraform provider is incompatible with
# Pi-hole v6.6+ (uses legacy PHP API). We use pihole-FTL --config
# via SSH instead, which is the native v6 configuration method.
# =============================================================================

locals {
  # Traefik service IP: use HA VIP if configured, otherwise nomad01
  traefik_ip = var.traefik_ha_vip != "" ? split("/", var.traefik_ha_vip)[0] : local.nomad01_ip

  # DNS target IP: use HA VIP if configured, otherwise dns-01
  dns_target_ip = var.dns_ha_vip != "" ? split("/", var.dns_ha_vip)[0] : var.dns_server_ip

  # All DNS A-records for Pi-hole
  # Format: "IP hostname hostname.domain"
  dns_records = concat(
    # Nomad node records
    [for name, ip in var.nomad_node_ips : "${ip} ${name} ${name}.${var.dns_postfix}"],

    # DNS alias (points to VIP or dns-01)
    var.dns_server_ip != "" ? ["${local.dns_target_ip} dns dns.${var.dns_postfix}"] : [],

    # Nomad services via Traefik
    [
      "${local.traefik_ip} vault vault.${var.dns_postfix}",
      "${local.traefik_ip} auth auth.${var.dns_postfix}",
      "${local.traefik_ip} traefik traefik.${var.dns_postfix}",
      "${local.traefik_ip} nomad nomad.${var.dns_postfix}",
      "${local.traefik_ip} pihole pihole.${var.dns_postfix}",
      "${local.traefik_ip} lam lam.${var.dns_postfix}",
      "${local.traefik_ip} netbox netbox.${var.dns_postfix}",
      "${local.traefik_ip} docs docs.${var.dns_postfix}",
      "${local.traefik_ip} ca ca.${var.dns_postfix}",
    ],

    # unifi-dns management app (behind Traefik) — only when deployed
    var.deploy_unifi_dns ? ["${local.traefik_ip} unifi-dns unifi-dns.${var.dns_postfix}"] : [],

    # Pulse monitoring (behind Traefik) — only when deployed
    var.deploy_pulse ? ["${local.traefik_ip} pulse pulse.${var.dns_postfix}"] : [],

    # Forgejo Git hosting (behind Traefik) — only when deployed
    var.deploy_forgejo ? ["${local.traefik_ip} git git.${var.dns_postfix}"] : [],

    # Kaneo project-management board (behind Traefik) — only when deployed
    var.deploy_kaneo ? ["${local.traefik_ip} tasks tasks.${var.dns_postfix}"] : [],

    # Uptime Kuma status page (behind Traefik) — only when deployed
    var.deploy_uptime_kuma ? ["${local.traefik_ip} status status.${var.dns_postfix}"] : [],

    # Kasm (direct IP, not behind Traefik)
    var.kasm_ip != "" ? ["${var.kasm_ip} kasm kasm.${var.dns_postfix}"] : [],

    # Proxmox node records
    [for name, ip in var.proxmox_node_ips : "${ip} ${name} ${name}.${var.dns_postfix}"],

    # Proxmox round-robin alias
    [for name, ip in var.proxmox_node_ips : "${ip} proxmox proxmox.${var.dns_postfix}"],
  )

  # UniFi wants discrete A-records {key=fqdn, value=ip}. Derive them from the
  # same dns_records source of truth: field[0]=ip, field[2]=fqdn. distinct()
  # dedupes; round-robin names (e.g. proxmox) keep one entry per ip.
  unifi_dns_records = distinct([
    for rec in local.dns_records : {
      key   = split(" ", rec)[2]
      value = split(" ", rec)[0]
    }
  ])
}

# --- Pi-hole DNS A-Records ---

resource "null_resource" "pihole_dns_records" {
  count = var.deploy_dns_records && contains(var.dns_backends, "pihole") ? 1 : 0

  triggers = {
    records_hash = sha256(jsonencode(local.dns_records))
    dns_server   = var.dns_server_ip
    # Persisted so the destroy-time provisioner (self.* only) can still reach
    # the host — destroy provisioners may not reference var.*.
    ssh_key_file = var.ssh_admin_private_key_file
  }

  # Uses self.triggers.* (not var.*) so the SAME connection block serves both
  # the create and the destroy-time provisioner. self.triggers is already
  # populated at create time, so this is safe for both.
  connection {
    type        = "ssh"
    host        = self.triggers.dns_server
    user        = "root"
    private_key = file(self.triggers.ssh_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      echo '[+] Updating Pi-hole DNS records (${length(local.dns_records)} records)...'
      pihole-FTL --config dns.hosts '${jsonencode(local.dns_records)}'
      pihole-FTL --config dns.cnameRecords '[]'
      echo '[+] DNS records configured'
      EOT
    ]
  }

  # Destroy-time prune: when the operator deselects the pihole backend, this
  # resource's count drops to 0 and Terraform destroys it — firing this. The
  # pihole writer owns dns.hosts wholesale (create REPLACES the whole array),
  # so pruning is simply writing '[]' back. A backend that was NEVER selected
  # never had this resource, so nothing runs for it (correct).
  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue # a retired/unreachable Pi-hole must not block the destroy
    inline = [
      "echo '[+] Pruning Pi-hole DNS records (backend deselected)...'",
      "pihole-FTL --config dns.hosts '[]' || echo '[!] Pi-hole unreachable; skipping'",
      "pihole-FTL --config dns.cnameRecords '[]' || true",
    ]
  }
}

# --- Nebula-Sync (propagate to replica Pi-holes) ---

resource "null_resource" "pihole_nebula_sync" {
  count      = var.deploy_dns_records && contains(var.dns_backends, "pihole") ? 1 : 0
  depends_on = [null_resource.pihole_dns_records]

  triggers = {
    records_hash = sha256(jsonencode(local.dns_records))
  }

  connection {
    type        = "ssh"
    host        = var.dns_server_ip
    user        = "root"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "systemctl start nebula-sync.service 2>/dev/null || echo '[!] Nebula-Sync not configured'",
      "echo '[+] DNS sync triggered'",
    ]
  }
}

# --- AD DNS Forwarding (dnsmasq conditional forward) ---

resource "null_resource" "ad_dns_forwarding" {
  count = var.deploy_dns_records && contains(var.dns_backends, "pihole") && var.ad_realm != "" ? 1 : 0

  triggers = {
    ad_realm = lower(var.ad_realm)
    dc01_ip  = local.nomad01_ip
  }

  connection {
    type        = "ssh"
    host        = var.dns_server_ip
    user        = "root"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      echo '[+] Configuring AD DNS forwarding for ${lower(var.ad_realm)}...'
      pihole-FTL --config dns.domain.local false
      pihole-FTL --config misc.dnsmasq_lines '["server=/${lower(var.ad_realm)}/${local.nomad01_ip}"]'
      systemctl restart pihole-FTL
      echo '[+] AD queries for ${lower(var.ad_realm)} forwarded to ${local.nomad01_ip}'
      EOT
    ]
  }
}

# --- Switch Nomad VMs to Pi-hole DNS ---
# Moved out of the Layer 2 apply: same reason as proxmox_dns_config.
# Switching Nomad VMs to Pi-hole DNS mid-deploy means subsequent
# nomad jobs pull docker images through a Pi-hole that may not yet
# have a working upstream — pulls fail with "server misbehaving" and
# the deploy implodes. Switching is now the absolute last thing
# deployAll does, via setNomadVMDNSToLab() in setup.sh. Manual
# control via dev menu d12 / d13.

# --- Update Proxmox nodes to use Pi-hole DNS ---
# Moved out of the Layer 2 apply: switching the Proxmox host's DNS to
# the lab Pi-hole is the LAST step of a deploy (everything else still
# uses the bootstrap-time external DNS). Handled by the bash helpers
# setProxmoxDNSToLab / revertProxmoxDNSToBootstrap in setup.sh, with
# menu options d12/d13. This way a half-broken deploy never leaves
# Proxmox unable to resolve archive.ubuntu.com on the next bootstrap.

# --- UniFi local-DNS records (static-dns API) ---
# UniFi's management API (:443 on the controller) is firewalled to nomad01 only,
# so this writer SSHes to nomad01 and curls the controller from there — the same
# host the unifi-dns app and netbox-sync already use. The reconcile is SCOPED:
# it only creates records from local.unifi_dns_records and only deletes records
# it previously created (tracked in /opt/unifi-dns-tf/managed.json on nomad01),
# so app- or hand-added UniFi records are never touched.
#
# The UniFi API key is passed to the remote script via the UNIFI_API_KEY env var
# (not baked into the file on disk). Note: it can appear in TF_LOG=debug output.

resource "null_resource" "unifi_dns_records" {
  count = var.deploy_dns_records && contains(var.dns_backends, "unifi") && var.unifi_address != "" ? 1 : 0

  triggers = {
    records_hash = sha256(jsonencode(local.unifi_dns_records))
    controller   = var.unifi_address
    site         = var.unifi_site
    # Persisted so the destroy-time provisioner (self.* only) can reach nomad01
    # and talk to the controller — destroy provisioners may not reference var.*.
    nomad01      = local.nomad01_ip
    ssh_key_file = var.ssh_admin_private_key_file
    unifi_address = var.unifi_address
    unifi_site    = var.unifi_site
    # The API key already lands in state via the create provisioner's inline
    # interpolation below, so persisting it here is parity (not new exposure)
    # and lets the scoped destroy prune authenticate.
    unifi_api_key = var.unifi_api_key
  }

  # Uses self.triggers.* (not var.*) so the SAME connection block serves both
  # the create and the destroy-time provisioner.
  connection {
    type        = "ssh"
    host        = self.triggers.nomad01
    user        = "labadmin"
    private_key = file(self.triggers.ssh_key_file)
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/unifi-dns-reconcile.sh.tpl", {
      unifi_address = var.unifi_address
      unifi_site    = var.unifi_site
      desired_json  = jsonencode(local.unifi_dns_records)
    })
    destination = "/tmp/unifi-dns-reconcile.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/unifi-dns-reconcile.sh",
      "sudo mkdir -p /opt/unifi-dns-tf",
      "UNIFI_API_KEY='${var.unifi_api_key}' sudo -E bash /tmp/unifi-dns-reconcile.sh",
      "rm -f /tmp/unifi-dns-reconcile.sh",
    ]
  }

  # Destroy-time SCOPED prune: when the operator deselects the unifi backend,
  # count drops to 0 and Terraform destroys this resource — firing this. We
  # only delete records this writer created, tracked in managed.json by the
  # reconcile script. Self-contained inline bash (no templatefile at destroy).
  # HCL-heredoc escaping: ${...} is TF interpolation (ONLY the three
  # self.triggers refs); every shell/jq variable is brace-free ($VAR / $(...))
  # so Terraform leaves it literal.
  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    inline = [
      <<-EOT
      set -u
      MANAGED=/opt/unifi-dns-tf/managed.json
      if [ ! -f "$MANAGED" ]; then echo '[+] no managed UniFi records to prune'; exit 0; fi
      BASE="https://${self.triggers.unifi_address}/proxy/network/v2/api/site/${self.triggers.unifi_site}/static-dns"
      KEY='${self.triggers.unifi_api_key}'
      exec 9>/var/lock/unifi-dns-tf.lock; flock -w 30 9 || { echo '[!] lock busy; skipping'; exit 0; }
      existing="$(curl -sk -m 15 -H "X-API-KEY: $KEY" -H 'Accept: application/json' "$BASE" || echo '[]')"
      echo '[+] Pruning UniFi DNS records (backend deselected)...'
      jq -r '.[]' "$MANAGED" 2>/dev/null | while IFS='|' read -r k v; do
        [ -z "$k" ] && continue
        id="$(printf '%s' "$existing" | jq -r --arg k "$k" --arg v "$v" '.[] | select(.record_type=="A" and .key==$k and .value==$v) | ._id' | head -1)"
        if [ -n "$id" ] && [ "$id" != "null" ]; then
          curl -sk -m 15 -X DELETE -H "X-API-KEY: $KEY" "$BASE/$id" >/dev/null && echo "  - pruned $k -> $v"
        fi
      done
      rm -f "$MANAGED"
      echo '[+] UniFi DNS prune complete'
      EOT
    ]
  }
}
