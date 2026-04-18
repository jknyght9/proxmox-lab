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

variable "deploy_traefik" {
  type    = bool
  default = true
}

variable "deploy_authentik" {
  type    = bool
  default = false
}

variable "deploy_samba_dc" {
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

variable "deploy_backup" {
  type    = bool
  default = false
}

variable "deploy_tailscale" {
  type    = bool
  default = false
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
