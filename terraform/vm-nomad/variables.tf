variable "dns_postfix" {
  type = string
}

variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint URL"
}

variable "template_node" {
  type        = string
  description = "Proxmox node where the nomad-template (9002) lives"
  default     = "pve01"
}

variable "proxmox_bridge" {
  type = string
}

# SSH key for Proxmox node administration (used by provisioners to upload snippets)
variable "ssh_enterprise_private_key_file" {
  type        = string
  description = "Path to enterprise private key for Proxmox node SSH"
}

# SSH key for VM administration (injected via cloud-init)
variable "ssh_admin_public_key_file" {
  type        = string
  description = "Path to admin public key for VM SSH"
}

variable "ssh_admin_private_key_file" {
  type        = string
  description = "Path to admin private key for VM SSH (used by remote-exec provisioners)"
  default     = "/crypto/labadmin"
}

variable "nomad_datacenter" {
  type    = string
  default = "dc1"
}

variable "nomad_region" {
  type    = string
  default = "global"
}

variable "gluster_mount_path" {
  type    = string
  default = "/srv/gluster/nomad-data"
}

variable "gluster_volume_name" {
  type    = string
  default = "nomad-data"
}

variable "node_ip_map" {
  type        = map(string)
  default     = {}
  description = "Map of Proxmox node names to their IP addresses for snippet uploads"
}

variable "dns_primary_ip" {
  type        = string
  default     = ""
  description = "Primary DNS server IP (Pi-hole). If empty, uses DHCP-provided DNS."
}

variable "vm_storage" {
  type        = string
  description = "Storage for VM disks (should match template storage)"
  default     = "local-lvm"
}

variable "vm_configs" {
  type = map(object({
    vm_id          = number
    name           = string
    cores          = number
    memory         = number
    disk_size      = string
    vm_state       = string
    target_node    = string
    target_storage = string
  }))
  default = {
    "nomad01" = { vm_id = 905, name = "nomad01", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve01", target_storage = "ceph-pool-01" }
    "nomad02" = { vm_id = 906, name = "nomad02", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve02", target_storage = "ceph-pool-01" }
    "nomad03" = { vm_id = 907, name = "nomad03", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve03", target_storage = "ceph-pool-01" }
  }
}

# Traefik HA Configuration (keepalived VIP)
variable "traefik_ha_enabled" {
  type        = bool
  description = "Enable Traefik HA with keepalived VIP"
  default     = false
}

variable "traefik_ha_vip" {
  type        = string
  description = "Virtual IP address for Traefik HA with CIDR"
  default     = ""
}

variable "traefik_ha_vrrp_router_id" {
  type        = number
  description = "VRRP router ID for Traefik HA"
  default     = 53
}

variable "traefik_ha_vrrp_password" {
  type        = string
  sensitive   = true
  description = "VRRP authentication password for Traefik HA"
  default     = "traefik"
}
