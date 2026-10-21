# =============================================================================
# Resource pool — the backup scope for everything this project deploys
#
# Guests reference this by name (pool_id) rather than being added after the
# fact, so membership is declarative: a destroyed VM leaves the pool, and a
# re-created one rejoins it, with no drift for a backup job to miss.
#
# The pool is NOT deleted on destroy if it still holds guests this project
# did not create — Proxmox refuses, which is the behaviour we want.
# =============================================================================

resource "proxmox_virtual_environment_pool" "lab" {
  count = var.resource_pool != "" ? 1 : 0

  pool_id = var.resource_pool
  comment = "Managed by proxmox-lab — backup scope for deployed guests"
}
