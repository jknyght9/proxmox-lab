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
      "${local.traefik_ip} status status.${var.dns_postfix}",
      "${local.traefik_ip} nomad nomad.${var.dns_postfix}",
      "${local.traefik_ip} pihole pihole.${var.dns_postfix}",
      "${local.traefik_ip} lam lam.${var.dns_postfix}",
      "${local.traefik_ip} netbox netbox.${var.dns_postfix}",
      "${local.traefik_ip} docs docs.${var.dns_postfix}",
      "${local.traefik_ip} ca ca.${var.dns_postfix}",
    ],

    # Kasm (direct IP, not behind Traefik)
    var.kasm_ip != "" ? ["${var.kasm_ip} kasm kasm.${var.dns_postfix}"] : [],

    # Proxmox node records
    [for name, ip in var.proxmox_node_ips : "${ip} ${name} ${name}.${var.dns_postfix}"],

    # Proxmox round-robin alias
    [for name, ip in var.proxmox_node_ips : "${ip} proxmox proxmox.${var.dns_postfix}"],
  )
}

# --- Pi-hole DNS A-Records ---

resource "null_resource" "pihole_dns_records" {
  count = var.deploy_dns_records ? 1 : 0

  triggers = {
    records_hash = sha256(jsonencode(local.dns_records))
    dns_server   = var.dns_server_ip
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
      echo '[+] Updating Pi-hole DNS records (${length(local.dns_records)} records)...'
      pihole-FTL --config dns.hosts '${jsonencode(local.dns_records)}'
      pihole-FTL --config dns.cnameRecords '[]'
      echo '[+] DNS records configured'
      EOT
    ]
  }
}

# --- Nebula-Sync (propagate to replica Pi-holes) ---

resource "null_resource" "pihole_nebula_sync" {
  count      = var.deploy_dns_records ? 1 : 0
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
  count = var.deploy_dns_records && var.ad_realm != "" ? 1 : 0

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

resource "null_resource" "nomad_dns_config" {
  for_each   = var.deploy_dns_records ? var.nomad_node_ips : {}
  depends_on = [null_resource.pihole_dns_records]

  triggers = {
    dns_server = local.dns_target_ip
  }

  connection {
    type        = "ssh"
    host        = each.value
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "sudo resolvectl dns eth0 ${local.dns_target_ip}",
      "sudo resolvectl domain eth0 ${var.dns_postfix}",
      "echo '[+] DNS set to ${local.dns_target_ip} on ${each.key}'",
    ]
  }
}

# --- Update Proxmox nodes to use Pi-hole DNS ---
# Moved out of the Layer 2 apply: switching the Proxmox host's DNS to
# the lab Pi-hole is the LAST step of a deploy (everything else still
# uses the bootstrap-time external DNS). Handled by the bash helpers
# setProxmoxDNSToLab / revertProxmoxDNSToBootstrap in setup.sh, with
# menu options d12/d13. This way a half-broken deploy never leaves
# Proxmox unable to resolve archive.ubuntu.com on the next bootstrap.
