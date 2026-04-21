# =============================================================================
# DNS Records — managed via ryanwholey/pihole Terraform provider
# =============================================================================

locals {
  # Traefik service IP: use HA VIP if configured, otherwise nomad01
  traefik_ip = var.traefik_ha_vip != "" ? split("/", var.traefik_ha_vip)[0] : local.nomad01_ip

  # DNS target IP: use HA VIP if configured, otherwise dns-01
  dns_target_ip = var.dns_ha_vip != "" ? split("/", var.dns_ha_vip)[0] : var.dns_server_ip

  # All DNS A-records to manage
  dns_a_records = merge(
    # Nomad node records
    { for name, ip in var.nomad_node_ips : "${name}.${var.dns_postfix}" => ip },

    # DNS alias
    var.dns_server_ip != "" ? { "dns.${var.dns_postfix}" = local.dns_target_ip } : {},

    # Nomad services via Traefik
    {
      "vault.${var.dns_postfix}"   = local.traefik_ip
      "auth.${var.dns_postfix}"    = local.traefik_ip
      "traefik.${var.dns_postfix}" = local.traefik_ip
      "status.${var.dns_postfix}"  = local.traefik_ip
      "nomad.${var.dns_postfix}"   = local.traefik_ip
      "pihole.${var.dns_postfix}"  = local.traefik_ip
      "lam.${var.dns_postfix}"     = local.traefik_ip
      "ca.${var.dns_postfix}"      = local.traefik_ip
    },

    # Kasm (direct IP, not behind Traefik)
    var.kasm_ip != "" ? { "kasm.${var.dns_postfix}" = var.kasm_ip } : {},

    # Proxmox node records
    { for name, ip in var.proxmox_node_ips : "${name}.${var.dns_postfix}" => ip },
  )
}

# --- Pi-hole DNS A-Records ---

resource "pihole_dns_record" "records" {
  for_each = var.deploy_dns_records ? local.dns_a_records : {}

  domain = each.key
  ip     = each.value
}

# --- Nebula-Sync (propagate records to replica Pi-holes) ---

resource "null_resource" "pihole_nebula_sync" {
  count      = var.deploy_dns_records ? 1 : 0
  depends_on = [pihole_dns_record.records]

  triggers = {
    records_hash = sha256(jsonencode(local.dns_a_records))
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
# The pihole provider doesn't support custom dnsmasq lines,
# so we use a null_resource for AD realm forwarding.

resource "null_resource" "ad_dns_forwarding" {
  count = var.deploy_dns_records && var.ad_realm != "" ? 1 : 0

  triggers = {
    ad_realm   = lower(var.ad_realm)
    dc01_ip    = local.nomad01_ip
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
  depends_on = [pihole_dns_record.records]

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

resource "null_resource" "proxmox_dns_config" {
  for_each   = var.deploy_dns_records ? var.proxmox_node_ips : {}
  depends_on = [pihole_dns_record.records]

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
