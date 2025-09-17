variable "proxmox_bridge" {
  type = string
  description = "Proxmox bridge interface"
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