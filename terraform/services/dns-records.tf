# =============================================================================
# DNS Records — Pi-hole local DNS configuration
# Replaces: lib/updateDNSRecords.sh
# =============================================================================

locals {
  # Traefik service IP: use HA VIP if configured, otherwise nomad01
  traefik_ip = var.traefik_ha_vip != "" ? split("/", var.traefik_ha_vip)[0] : local.nomad01_ip

  # DNS target IP: use HA VIP if configured, otherwise dns-01
  dns_target_ip = var.dns_ha_vip != "" ? split("/", var.dns_ha_vip)[0] : var.dns_server_ip

  # Build the full DNS records list for Pi-hole
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
      "${local.traefik_ip} ca ca.${var.dns_postfix}",
    ],

    # Proxmox node records
    [for name, ip in var.proxmox_node_ips :
      "${ip} ${name} ${name}.${var.dns_postfix}"],

    # Proxmox round-robin alias
    [for name, ip in var.proxmox_node_ips :
      "${ip} proxmox proxmox.${var.dns_postfix}"],
  )
}

resource "null_resource" "pihole_dns_records" {
  # Only run if DNS server is available
  count = var.dns_server_ip != "" ? 1 : 0

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
      echo '[+] Updating Pi-hole DNS records...'
      pihole-FTL --config dns.hosts '${jsonencode(local.dns_records)}'
      pihole-FTL --config dns.cnameRecords '[]'
      echo '[+] ${length(local.dns_records)} DNS records configured'
      EOT
    ]
  }
}

# Trigger Nebula-Sync to propagate to replica Pi-holes
resource "null_resource" "pihole_nebula_sync" {
  count      = var.dns_server_ip != "" ? 1 : 0
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

# Update Proxmox nodes to use Pi-hole DNS
resource "null_resource" "proxmox_dns_config" {
  for_each   = var.dns_server_ip != "" ? var.proxmox_node_ips : {}
  depends_on = [null_resource.pihole_dns_records]

  triggers = {
    dns_server = local.dns_target_ip
  }

  connection {
    type        = "ssh"
    host        = each.value
    user        = "root"
    private_key = file(var.ssh_enterprise_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "pvesh set /nodes/${each.key}/dns -dns1 ${local.dns_target_ip} -search ${var.dns_postfix}",
      "echo '[+] DNS set to ${local.dns_target_ip} on ${each.key}'",
    ]
  }
}
