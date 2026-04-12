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
variable "vault_addr" {
  type        = string
  description = "Vault address for fetching PKI root CA (e.g., https://10.1.50.114:8200). The VM fetches the cert directly during build."
}

# SSH key for Proxmox node administration (used by base template builders)
variable "ssh_enterprise_key_file" {
  type        = string
  description = "Path to enterprise private key for Proxmox node SSH"
  default     = "/crypto/labenterpriseadmin"
}

# Network config for base template agent installation (temp static IP)
variable "network_gateway" {
  type        = string
  description = "Network gateway for temporary static IP during base template agent install"
  default     = ""
}
variable "network_cidr_mask" {
  type        = string
  description = "CIDR mask bits (e.g., 24)"
  default     = "24"
}

# Base template VMIDs and image URLs
variable "base_ubuntu_vmid" {
  type    = number
  default = 9999
}
variable "ubuntu_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}
variable "base_fedora_vmid" {
  type    = number
  default = 9998
}
variable "fedora_image_url" {
  type    = string
  default = "https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
}
variable "base_debian_vmid" {
  type    = number
  default = 9997
}
variable "debian_image_url" {
  type    = string
  default = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
}