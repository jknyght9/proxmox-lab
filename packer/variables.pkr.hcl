variable "proxmox_url"    { type = string }
variable "proxmox_node"   { type = string }
variable "proxmox_token_id"  { type = string }
variable "proxmox_token_secret" { type = string }
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
variable "ssh_private_key_file" { 
  type = string 
  default = "/crypto/lab-deploy"
}
variable "ssh_public_key_file" { 
  type = string 
  default = "/crypto/lab-deploy.pub"
}
variable "docker_name" {
  type = string 
  default = "docker-template"
}
variable "docker_vmid" {
  type = number 
  default = 9001
}
variable "kasm_name" {
  type = string 
  default = "kasm-1.17-template"
}
variable "kasm_vmid" {
  type = number 
  default = 9100
}
variable "kasm_version" { 
  type = string
  default = "1.17.0.7f020d"
}
variable "kasm_admin_password" {
  type = string 
  default = "changeme123"
}
variable "win10_iso" { 
  type = string
  default = "local:iso/win10.iso"
}
variable "win10_vmid" { 
  type = number
  default = 9200
}
