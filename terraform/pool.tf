# =============================================================================
# Resource pool — the backup scope for everything this project deploys
#
# Terraform owns the pool OBJECT only. Membership is applied afterwards by
# ensurePoolMembership() in lib/proxmox/backupJob.sh.
#
# Why not pool_id on each guest: the provider sets the pool during the clone
# and then PUTs the membership again, which Proxmox rejects with
# "VM <id> is already a pool member" (HTTP 500). The guest is created but the
# resource errors, leaving a VM that exists, is in the pool, and is absent from
# Terraform state. Verified on 0.106 with VMs 905-907.
#
# The pool is NOT deleted on destroy while it still holds guests this project
# did not create — Proxmox refuses, which is the behaviour we want.
# =============================================================================

resource "proxmox_virtual_environment_pool" "lab" {
  count = var.resource_pool != "" ? 1 : 0

  pool_id = var.resource_pool
  comment = "Managed by proxmox-lab — backup scope for deployed guests"
}
