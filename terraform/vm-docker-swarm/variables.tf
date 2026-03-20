variable "dns_postfix" {
  type = string
}

variable proxmox_api_url {
  type = string
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

variable vm_configs {
  type = map(object({
    vm_id = number
    name = string 
    cores = number
    memory = number
    disk_size = string
    vm_state = string
    target_node = string
    target_storage = string
  }))
  default = {
    "docker01" = { vm_id = 905, name = "docker01", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve01", target_storage = "ceph-pool-01" }
    "docker02" = { vm_id = 906, name = "docker02", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve02", target_storage = "ceph-pool-01" }
    "docker03" = { vm_id = 907, name = "docker03", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve03", target_storage = "ceph-pool-01" }
  }
}