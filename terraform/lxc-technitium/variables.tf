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
  description = "Technitium admin password"
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
