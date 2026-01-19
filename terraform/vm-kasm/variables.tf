variable "dns_postfix" {
  type = string
}

variable "kasm_admin_password" {
  type = string 
}

variable "kasm_version" { 
  type = string
}

variable proxmox_api_url {
  type = string
}

variable "proxmox_bridge" {
  type = string
}

variable "ssh_public_key_file" {
  type = string
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
    "kasm01" = { vm_id = 910, name = "kasm01", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve01", target_storage = "ceph-pool-01" }
  }
}