variable vm_configs {
  type = map(object({
    vm_id = number
    name = string 
    cores = number
    memory = number
    disk_size = string
    vm_state = string
    target_node = string
  }))
  default = {
    "docker01" = { vm_id = 905, name = "docker01", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve" }
    "docker02" = { vm_id = 906, name = "docker02", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve" }
    "docker03" = { vm_id = 907, name = "docker03", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve" }
  }
}