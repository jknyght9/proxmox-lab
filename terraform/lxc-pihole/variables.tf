variable "cluster_name" {
  type        = string
  description = "Name of the DNS cluster (e.g., 'main', 'labnet')"
}

variable "nodes" {
  type = list(object({
    hostname    = string
    target_node = string
    ip          = string
    gw          = string
  }))
  description = "List of DNS nodes to create"
}

variable "network_bridge" {
  type        = string
  description = "Proxmox network bridge (e.g., 'vmbr0', 'labnet')"
}

variable "admin_password" {
  type        = string
  description = "Pi-hole web admin password"
  sensitive   = true
}

variable "root_password" {
  type        = string
  description = "LXC container root password"
  sensitive   = true
}

variable "proxmox_api_url" {
  type        = string
  description = "Proxmox API URL for extracting host"
}

variable "vmid_start" {
  type        = number
  description = "Starting VMID for containers"
  default     = 910
}

variable "ostemplate" {
  type        = string
  description = "OS template for container"
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "cores" {
  type        = number
  description = "Number of CPU cores per container"
  default     = 2
}

variable "memory" {
  type        = number
  description = "Memory in MB per container"
  default     = 1024
}

variable "disk_size" {
  type        = string
  description = "Disk size for root filesystem"
  default     = "4G"
}

variable "storage" {
  type        = string
  description = "Storage for root filesystem (e.g., 'local-lvm', 'ceph', 'nfs-storage')"
  default     = "local-lvm"
}

variable "is_sdn_network" {
  type        = bool
  description = "Whether this uses SDN (requires pct exec for provisioning instead of direct SSH)"
  default     = false
}

variable "proxmox_ssh_host" {
  type        = string
  description = "Default Proxmox host IP for pct exec (fallback when node_ip_map is empty)"
  default     = ""
}

variable "node_ip_map" {
  type        = map(string)
  description = "Map of Proxmox node names to their IP addresses (e.g., {pve01 = \"10.1.50.210\", pve02 = \"10.1.50.211\"})"
  default     = {}
}

variable "dns_zone" {
  type        = string
  description = "Primary DNS zone to create (e.g., 'lab', 'mylab.lan')"
  default     = ""
}

variable "bootstrap_dns" {
  type        = string
  description = "DNS server to use during initial provisioning (before Pi-hole is running)"
  # Required - passed from parent module
}

# DHCP Configuration (primarily for labnet/SDN networks)
variable "dhcp_enabled" {
  type        = bool
  description = "Enable DHCP server on Pi-hole (for labnet SDN networks)"
  default     = false
}

variable "dhcp_start" {
  type        = string
  description = "Start of DHCP IP range (e.g., '172.16.0.100')"
  default     = ""
}

variable "dhcp_end" {
  type        = string
  description = "End of DHCP IP range (e.g., '172.16.0.200')"
  default     = ""
}

variable "dhcp_router" {
  type        = string
  description = "DHCP gateway/router IP (usually the SDN gateway)"
  default     = ""
}

variable "dhcp_lease_time" {
  type        = string
  description = "DHCP lease time in seconds"
  default     = "86400"
}

# ============================================================================
# High Availability (keepalived) Configuration
# ============================================================================

variable "enable_ha_vip" {
  type        = bool
  description = "Enable keepalived VIP for Pi-hole HA (requires privileged containers)"
  default     = false
}

variable "ha_vip_address" {
  type        = string
  description = "Virtual IP address for DNS HA with CIDR (e.g., '10.1.50.3/24')"
  default     = ""
}

variable "ha_vrrp_router_id" {
  type        = number
  description = "VRRP router ID (must be unique on network, 1-255)"
  default     = 51
}

variable "ha_vrrp_password" {
  type        = string
  sensitive   = true
  description = "VRRP authentication password (8 chars max)"
  default     = ""
}

# ============================================================================
# SSH Key Configuration
# ============================================================================

# SSH key for Proxmox node administration (used by provisioners)
variable "ssh_enterprise_private_key_file" {
  type        = string
  description = "Path to enterprise private key for Proxmox node SSH"
  default     = "/crypto/labenterpriseadmin"
}

# SSH key for container administration (injected into containers)
variable "ssh_admin_public_key_file" {
  type        = string
  description = "Path to admin public key for container SSH"
  default     = "/crypto/labadmin.pub"
}

# SSH key for container administration (used by direct provisioners)
variable "ssh_admin_private_key_file" {
  type        = string
  description = "Path to admin private key for container SSH"
  default     = "/crypto/labadmin"
}
