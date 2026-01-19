variable "dns_postfix" { type = string }
variable "docker_name" {
  type = string 
  default = "docker-template"
}
variable "docker_vmid" {
  type = number 
  default = 9001
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
variable "ssh_private_key_file" { 
  type = string 
  default = "/crypto/lab-deploy"
}
variable "ssh_public_key_file" { 
  type = string 
  default = "/crypto/lab-deploy.pub"
}