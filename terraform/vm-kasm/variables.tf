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
  type        = string
  description = "Kasm Workspaces version (format: X.Y.Z.hash from kasmweb.com/downloads)"
  default     = "1.18.0.09f70a"
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

variable "ssh_admin_private_key_file" {
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
  description = "Kasm VM configurations. Required — passed in by parent module from bootstrap-generated tfvars (no hardcoded defaults so we don't quietly use a previous lab's IPs)."
}
