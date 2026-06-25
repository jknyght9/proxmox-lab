# =============================================================================
# Vault-stored ZFS encryption keys for TrueNAS datasets
#
# Generates a 256-bit random key per name and stores at
# secret/truenas/zfs-keys/<name>. Operators pass these keys when creating
# encrypted ZFS datasets via the TrueNAS REST API (raw hex format). Vault
# is the source of truth — if a TrueNAS host is rebuilt, datasets can be
# re-unlocked from the Vault-stored key.
#
# prevent_destroy: ZFS encryption keys cannot be safely regenerated. The
# raw key is wrapped by the user key at dataset-create time; rotating the
# Terraform value here would silently desync from the dataset, breaking
# unlock. Use `zfs change-key` to rotate at the dataset layer if needed,
# and update the Vault entry out-of-band.
#
# Lab-specific key names live in a separate lab-extensions overlay
# (lab-vault-zfs-keys.auto.tfvars).
# =============================================================================

variable "zfs_encryption_keys" {
  description = "Names of ZFS encryption keys to generate and store in Vault at secret/truenas/zfs-keys/<name>. Typically populated by a lab-extensions overlay."
  type        = list(string)
  default     = []
}

resource "random_bytes" "zfs_encryption_keys" {
  for_each = toset(var.zfs_encryption_keys)
  length   = 32 # 256-bit → 64 hex chars (matches TrueNAS raw-key format)
  keepers  = { key_name = each.value }
  lifecycle { prevent_destroy = true }
}

resource "vault_kv_secret_v2" "zfs_encryption_keys" {
  for_each = toset(var.zfs_encryption_keys)
  mount    = vault_mount.secret.path
  name     = "truenas/zfs-keys/${each.value}"
  data_json = jsonencode({
    key_hex = random_bytes.zfs_encryption_keys[each.value].hex
    purpose = "ZFS native encryption key — ${each.value}"
  })
  # prevent_destroy: matches the random_bytes guard. Without both, an
  # accidental destroy + state loss orphans encrypted ZFS datasets — the
  # blocks remain on disk but the wrapping key is unrecoverable.
  lifecycle { prevent_destroy = true }
}
