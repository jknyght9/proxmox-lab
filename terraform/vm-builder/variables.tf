variable "dns_postfix" {
  type = string
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
  description = "Build-runner VM configurations. Required — passed in by parent module from bootstrap-generated tfvars."
}

variable "runner_image" {
  type        = string
  description = "forgejo-runner image (same pin as the services-layer forgejo-runner job)"
  default     = "code.forgejo.org/forgejo/runner:13.1.0"
}

variable "runner_labels" {
  type        = string
  description = "Comma-separated label:docker://image list registered for this runner"
}

variable "runner_capacity" {
  type        = number
  description = "Concurrent jobs per build VM (heavy builds: keep low)"
  default     = 1
}

variable "runner_registration_token" {
  type        = string
  sensitive   = true
  description = "Instance-level Forgejo runner registration token (secret/forgejo-runner)"
}

variable "root_ca_pem" {
  type        = string
  description = "Internal root CA (Vault pki/cert/ca), trusted by the VM, its Docker daemon and job containers"
}

variable "docker_prune_until" {
  type        = string
  description = "Nightly prune removes unused images/build cache older than this (docker filter 'until')"
  default     = "72h"
}
