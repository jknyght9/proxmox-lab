variable "dns_postfix" {
  type = string
}

variable "dns_primary_ip" {
  type    = string
  default = ""
}

variable "kasm_admin_password" {
  type      = string
  sensitive = true
}

variable "kasm_version" {
  type    = string
  default = "1.16.1.98d6d9"
}

variable "proxmox_endpoint" {
  type = string
}

variable "proxmox_bridge" {
  type = string
}

variable "template_node" {
  type        = string
  description = "Proxmox node where the docker-template (9001) lives"
  default     = "pve01"
}

variable "ssh_enterprise_private_key_file" {
  type = string
}

variable "ssh_admin_public_key_file" {
  type = string
}

variable "vm_storage" {
  type    = string
  default = "local-lvm"
}

variable "node_ip_map" {
  type    = map(string)
  default = {}
}

variable "network_gateway" {
  type = string
}

variable "network_cidr_bits" {
  type    = string
  default = "24"
}

variable "vm_configs" {
  type = map(object({
    vm_id          = number
    name           = string
    ip             = string
    cores          = number
    memory         = number
    disk_size      = string
    vm_state       = string
    target_node    = string
    target_storage = string
  }))
  default = {
    "kasm01" = { vm_id = 930, name = "kasm01", ip = "10.1.50.120", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve01", target_storage = "ceph-pool-01" }
  }
}
