variable "dns_postfix" { type = string }
variable "docker_name" {
  type = string 
  default = "docker-template"
}
variable "docker_vmid" {
  type = number
  default = 9001
}
variable "nomad_name" {
  type    = string
  default = "nomad-template"
}
variable "nomad_vmid" {
  type    = number
  default = 9002
}
variable "template_storage" {
  type        = string
  default     = "local"
  description = "Storage for Packer templates. Use shared storage (e.g., ceph-pool-01) for multi-node clusters."
}
variable "template_storage_type" {
  type        = string
  default     = "lvm"
  description = "Storage type: nfs, rbd, lvm, cephfs, dir, etc."
}
variable "proxmox_node" { type = string }
variable "proxmox_token_id" { type = string }
variable "proxmox_token_secret" { type = string }
variable "proxmox_url" { type = string }
variable root_password {
  type = string 
  default = "changeme123"
}
variable ssh_username {
  type = string 
  default = "labadmin"
} 
variable ssh_password {
  type = string
  default = "changeme123"
}
# SSH key for VM administration (templates use admin key, not enterprise key)
variable "ssh_private_key_file" {
  type = string
  description = "Path to admin private key for VM SSH"
  default = "/crypto/labadmin"
}
variable "ssh_public_key_file" {
  type = string
  description = "Path to admin public key for VM SSH"
  default = "/crypto/labadmin.pub"
}
variable "network_bridge" {
  type        = string
  description = "Proxmox network bridge for Packer VMs (must be reachable from Docker)"
  default     = "vmbr0"
}