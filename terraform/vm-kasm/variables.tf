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
    "kasm01" = { vm_id = 910, name = "kasm01", cores = 4, memory = 8192, disk_size = "100G", vm_state = "running", target_node = "pve" }
  }
}