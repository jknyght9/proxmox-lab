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

variable "deploy_csi" {
  type        = bool
  description = "Deploy the CSI plugin (csi-driver-nfs) that mounts NFS shares from the cluster_state NAS into Nomad jobs. Required before any service can be migrated off GlusterFS."
  default     = false
}

variable "csi_driver_nfs_version" {
  type        = string
  description = "Image tag for registry.k8s.io/sig-storage/nfsplugin"
  default     = "v4.11.0"
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


# Removed: var.deploy_backup. See vault-secrets.tf / nomad-jobs.tf comments.

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

# Removed: backup_type/backup_nfs_*/backup_smb_* variables. The explicit
# backup Nomad job was retired in Phase 2/3 of the storage migration;
# ZFS snapshots on the cluster_state NAS handle the backup role now
# (configured via storage.snapshots in bootstrap.yml).

# =============================================================================
# Tailscale Subnet Routers (optional — every Nomad node runs tailscaled,
# advertising the lab subnet so remote tailnet clients can reach lab IPs)
# =============================================================================

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  description = "Reusable Tailscale auth key (login.tailscale.com → Settings → Keys). Stored in Vault."
  default     = ""
}

variable "tailscale_advertise_routes" {
  type        = string
  description = "CSV of subnets the tailnet should reach via these routers (e.g. '10.10.0.0/24'). Defaults to network_cidr."
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

# Removed: var.backup_cron / backup_timezone / backup_retention_days.
# Snapshot cadence + retention now live under storage.snapshots in
# bootstrap.yml; see plans/serene-brewing-cray.md.

# Periodic Netbox inventory sync (UniFi → Netbox).
# Default: every 6 hours. Override in bootstrap.yml as netbox_sync_cron.
variable "netbox_sync_cron" {
  type    = string
  default = "0 */6 * * *"
}

variable "netbox_sync_timezone" {
  type    = string
  default = "UTC"
}

# Periodic profile-folder reconciler (AD users → per-user folders on profile NAS).
# Default: every 15 minutes. Override in bootstrap.yml as profile_reconciler_cron.
variable "profile_reconciler_cron" {
  type    = string
  default = "*/15 * * * *"
}

variable "profile_reconciler_timezone" {
  type    = string
  default = "UTC"
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
    # ZFS pool name on this NAS. Required if this NAS plays any storage role
    # (cluster_state, profiles). Empty for NASes used only for AD-join
    # discovery or future read-only roles.
    pool = optional(string, "")
    # Roaming-profile fields — opt-in per NAS. If provides_profiles=false (or
    # omitted), the profile-share + reconciler logic is a no-op for this host.
    provides_profiles = optional(bool, false)
    profile_dataset   = optional(string, "")
    profile_ad_group  = optional(string, "Domain Users")
  }))
  description = "NAS servers to join to the AD domain"
  default     = []
}

# =============================================================================
# NAS Storage Roles (cluster_state for Nomad CSI/NFS, plus snapshot policy)
# =============================================================================
# Drives which NAS provides pooled cluster storage and how it's snapshotted.
# Block is generated by lib/bootstrap.sh from the bootstrap.yml `storage:`
# block. cluster_state.nas must reference an entry in var.nas_servers by name.
#
# Deploy refuses to proceed if cluster_state.nas is empty (no fallback to
# GlusterFS — see plans/serene-brewing-cray.md for the migration arc).
variable "nas_storage" {
  type = object({
    cluster_state = object({
      nas          = string           # name of entry in var.nas_servers
      dataset_root = optional(string, "nomad")
      allow_hosts  = optional(string, "") # blank = use network_cidr
    })
    snapshots = object({
      schedule          = optional(string, "hourly")
      retention_hourly  = optional(number, 96)
      retention_daily   = optional(number, 30)
      retention_monthly = optional(number, 12)
      replicate_to = optional(object({
        nas  = optional(string, "")
        pool = optional(string, "")
      }), { nas = "", pool = "" })
    })
  })
  description = "NAS storage role bindings — which NAS provides pooled cluster storage, snapshot/retention policy, optional replication target."
  default = {
    cluster_state = { nas = "" }
    snapshots     = {}
  }
}
