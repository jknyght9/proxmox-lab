# =============================================================================
# Provider Addresses
# =============================================================================

variable "vault_address" {
  type        = string
  description = "Vault API address (e.g., https://10.1.50.114:8200)"
}

variable "vault_token" {
  type        = string
  sensitive   = true
  description = "Vault root token"
}

variable "nomad_address" {
  type        = string
  description = "Nomad API address (e.g., http://10.1.50.114:4646)"
}

# =============================================================================
# Cluster Configuration
# =============================================================================

variable "dns_postfix" {
  type        = string
  description = "Domain suffix for all services (e.g., jdclabs.lan)"
}

variable "nomad_node_ips" {
  type        = map(string)
  description = "Map of Nomad node names to IPs (e.g., {nomad01 = \"10.1.50.114\"})"
}

variable "vm_inventory" {
  type = map(object({
    vm_id       = number
    ip          = string
    cores       = number
    memory      = number
    disk_size   = string
    target_node = string
  }))
  description = "All VM configs for Netbox inventory (from Layer 1 vm_configs)"
  default     = {}
}

variable "lxc_inventory" {
  type = map(object({
    ip          = string
    target_node = string
    role        = string
  }))
  description = "All LXC container configs for Netbox inventory"
  default     = {}
}

variable "dns_server_ip" {
  type        = string
  description = "Primary DNS server IP (Pi-hole VIP or dns-01)"
}

variable "network_gateway" {
  type        = string
  description = "Network gateway IP"
}

variable "network_cidr" {
  type        = string
  description = "Network CIDR (e.g., 10.1.50.0/24)"
}

# =============================================================================
# SSH Keys (for null_resource provisioners)
# =============================================================================

variable "ssh_admin_private_key_file" {
  type        = string
  description = "Path to admin SSH private key for Nomad VM access"
}

variable "ssh_admin_public_key_file" {
  type        = string
  description = "Path to admin SSH public key"
}

variable "ssh_enterprise_private_key_file" {
  type        = string
  description = "Path to enterprise SSH private key for Proxmox access"
}

# =============================================================================
# Service Toggles
# =============================================================================

variable "kasm_ip" {
  type        = string
  description = "Kasm Workspaces VM IP (for DNS record). Empty if not deployed."
  default     = ""
}

variable "pihole_admin_password" {
  type        = string
  sensitive   = true
  description = "Pi-hole admin password (for API access)"
  default     = ""
}

variable "authentik_api_token" {
  type        = string
  sensitive   = true
  description = "Authentik API token (bootstrap token for provider auth)"
  default     = "not-configured"
}

variable "deploy_dns_records" {
  type        = bool
  description = "Configure Pi-hole DNS records (requires DNS containers to be deployed first)"
  default     = false
}

variable "deploy_traefik" {
  type    = bool
  default = true
}

variable "deploy_authentik" {
  type        = bool
  description = "Deploy Authentik Nomad job"
  default     = false
}

variable "configure_authentik" {
  type        = bool
  description = "Configure Authentik apps/providers (requires Authentik to be running first)"
  default     = false
}

variable "deploy_samba_ad" {
  type    = bool
  default = false
}

variable "deploy_uptime_kuma" {
  type    = bool
  default = false
}

variable "deploy_lam" {
  type    = bool
  default = false
}

variable "deploy_netbox" {
  type        = bool
  description = "Deploy Netbox inventory management"
  default     = false
}

variable "configure_netbox" {
  type        = bool
  description = "Configure Netbox provider resources (requires Netbox to be running first)"
  default     = false
}

variable "netbox_api_token" {
  type        = string
  sensitive   = true
  description = "Netbox API token (bootstrap token for provider auth)"
  default     = "not-configured"
}

variable "vault_oidc_client_secret" {
  type        = string
  sensitive   = true
  description = "Vault OIDC client secret from Authentik (stored at secret/vault-oidc)"
  default     = ""
}

variable "deploy_backup" {
  type    = bool
  default = false
}

# =============================================================================
# UniFi Controller (for Netbox inventory sync)
# =============================================================================

variable "unifi_address" {
  type        = string
  description = "UniFi Controller IP or FQDN"
  default     = ""
}

variable "unifi_api_key" {
  type        = string
  sensitive   = true
  description = "UniFi Controller API key"
  default     = ""
}

variable "unifi_site" {
  type        = string
  description = "UniFi site name"
  default     = "default"
}

variable "deploy_tailscale" {
  type    = bool
  default = false
}

# =============================================================================
# HA Configuration (VIP addresses)
# =============================================================================

variable "traefik_ha_vip" {
  type        = string
  description = "Traefik keepalived VIP (e.g., 10.1.50.100/24). Empty if HA disabled."
  default     = ""
}

variable "dns_ha_vip" {
  type        = string
  description = "DNS keepalived VIP (e.g., 10.1.50.3/24). Empty if HA disabled."
  default     = ""
}

variable "proxmox_node_ips" {
  type        = map(string)
  description = "Map of Proxmox node names to IPs (for DNS records)"
  default     = {}
}

# =============================================================================
# AD Configuration (used by samba-dc, lam, domain-join)
# =============================================================================

variable "ad_realm" {
  type        = string
  description = "Active Directory realm (e.g., JDCLABS.LAN)"
  default     = ""
}

variable "ad_domain" {
  type        = string
  description = "Active Directory NetBIOS domain (e.g., JDCLABS)"
  default     = ""
}

# =============================================================================
# Backup Configuration
# =============================================================================

variable "backup_cron" {
  type    = string
  default = "0 2 * * *"
}

variable "backup_timezone" {
  type    = string
  default = "UTC"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

# =============================================================================
# NAS Servers (AD domain join via API)
# =============================================================================

variable "nas_servers" {
  type = list(object({
    name           = string
    type           = string # "truenas" or "synology"
    address        = string
    api_key        = optional(string, "")
    admin_user     = optional(string, "")
    admin_password = optional(string, "")
  }))
  description = "NAS servers to join to the AD domain"
  default     = []
}
