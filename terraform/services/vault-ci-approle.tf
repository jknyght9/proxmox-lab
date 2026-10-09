# =============================================================================
# Forgejo-Actions CI identities — Vault AppRole pattern for infra-* repos
#
# Each `infra-*` deployment repo (first consumer: infra-role-emba; future:
# infra-arachne, …) gets its own Vault AppRole + least-privilege read policy +
# a DEDICATED CI SSH keypair. A Forgejo workflow authenticates with the AppRole
# (role_id + secret_id as Forgejo repo secrets), fetches a short-lived token,
# and reads only the secrets that repo's Terragrunt needs.
#
# Security posture (approved 2026-10-09):
#   - DEDICATED CI SSH key per repo — NOT secret/ssh-keys (that holds the
#     operator labadmin AND the enterprise/Proxmox-node keys). The CI key's
#     pubkey is injected into the VMs the repo provisions (via its own cloud-init,
#     which reads secret/ci/<repo>/ssh) and registered as a read-only deploy key
#     on the module-source repo; it is independently revocable.
#   - Per-repo policy is read-only, least-privilege.
#   - AppRole secret_id is non-expiring BUT CIDR-bound to the runner subnet, and
#     issued tokens are short-lived (20m / 1h max) — a stolen secret_id is
#     useless off-network and tokens expire fast.
#
# NOT managed here (operator-populated; this file only grants READ on them):
#   - secret/proxmox       — a DEDICATED Proxmox CI token (operator mints in
#                            Proxmox, then: vault kv put secret/proxmox
#                            token_id=... token=...). Not in TF so the token
#                            never lands in tfvars/state.
#   - secret/versitygw     — the shared versitygw S3 state-backend key (exists
#                            out-of-band). Per-repo prefix-scoped IAM is the
#                            future hardening (pm-code-repo).
#
# OPERATOR RUNBOOK (after `tf-services apply` of these resources):
#   1. Mint the Proxmox CI token + `vault kv put secret/proxmox ...` (see above).
#   2. Pull a secret_id (lifecycle stays operator-owned, never in TF state):
#        vault write -f auth/approle/role/<repo>/secret-id
#      and read the role_id from the `infra_ci_role_ids` output.
#   3. Set role_id + secret_id as Forgejo repo secrets on <repo>.
#   4. Register the CI pubkey (secret/ci/<repo>/ssh → public_key) as a read-only
#      deploy key on the module-source repo (infra-lab-templates).
#
# TEMPLATE: add a new infra-* CI identity by adding an entry to
# var.infra_ci_repos (in the lab-ci-approles.auto.tfvars overlay) — no code
# change. See lab-ci-approles.auto.tfvars.example.
# =============================================================================

variable "infra_ci_repos" {
  description = <<-EOT
    Forgejo-Actions CI identities, keyed by infra-* repo name. `secret_read_paths`
    are KV-v2 logical paths (WITHOUT the `secret/data/` prefix) that repo's
    Terragrunt needs, beyond the common set (tofu/state-encryption + versitygw +
    the repo's own ci/<repo>/ssh). Populated from a lab-*.auto.tfvars overlay so
    no site-specific repo names live in the tracked repo. Empty => no CI AppRoles.
  EOT
  type = map(object({
    secret_read_paths = list(string)
  }))
  default = {}
}

variable "infra_ci_bound_cidrs" {
  description = "CIDRs the CI AppRole secret_id + issued tokens are bound to (the Forgejo runner subnet). A stolen secret_id is unusable outside these."
  type        = list(string)
  default     = ["10.10.0.0/24"]
}

locals {
  infra_ci_enabled = length(var.infra_ci_repos) > 0

  # Paths every infra-* CI identity reads, in addition to its per-repo set and
  # its own CI SSH key: the shared OpenTofu state-encryption passphrase and the
  # shared versitygw S3 state-backend key.
  infra_ci_common_paths = [
    "tofu/state-encryption",
    "versitygw",
  ]
}

# --- AppRole auth method (enabled once when any CI identity is configured) -----
# If approle is already enabled out-of-band, import before apply:
#   tf-services import 'vault_auth_backend.approle[0]' approle
resource "vault_auth_backend" "approle" {
  count = local.infra_ci_enabled ? 1 : 0
  type  = "approle"
}

# --- Shared OpenTofu 1.11+ state-encryption passphrase (operators + all CI) ----
# MIRROR the EXISTING passphrase at secret/opentofu/state-encryption (which
# already encrypts live state) into the canonical secret/tofu/state-encryption
# path CI reads. We must NOT generate a fresh one — CI would then be unable to
# decrypt existing state. Operators migrate to the tofu/ path over time;
# opentofu/ remains the source mirror until cutover.
data "vault_kv_secret_v2" "opentofu_state_encryption" {
  count = local.infra_ci_enabled ? 1 : 0
  mount = vault_mount.secret.path
  name  = "opentofu/state-encryption"
}

resource "vault_kv_secret_v2" "tofu_state_encryption" {
  count     = local.infra_ci_enabled ? 1 : 0
  mount     = vault_mount.secret.path
  name      = "tofu/state-encryption"
  data_json = jsonencode({ passphrase = data.vault_kv_secret_v2.opentofu_state_encryption[0].data["passphrase"] })
  lifecycle { prevent_destroy = true }
}

# --- Per-repo: dedicated CI SSH keypair ----------------------------------------
# ED25519; stored in Vault at secret/ci/<repo>/ssh (private_key + public_key).
# This is NOT the operator labadmin/enterprise key.
resource "tls_private_key" "infra_ci_ssh" {
  for_each  = var.infra_ci_repos
  algorithm = "ED25519"
}

resource "vault_kv_secret_v2" "infra_ci_ssh" {
  for_each = var.infra_ci_repos
  mount    = vault_mount.secret.path
  name     = "ci/${each.key}/ssh"
  data_json = jsonencode({
    private_key = tls_private_key.infra_ci_ssh[each.key].private_key_openssh
    public_key  = tls_private_key.infra_ci_ssh[each.key].public_key_openssh
  })
}

# --- Per-repo: read-only least-privilege policy --------------------------------
resource "vault_policy" "infra_ci" {
  for_each = var.infra_ci_repos
  name     = "${each.key}-ci"
  policy = join("\n", [
    for p in concat(local.infra_ci_common_paths, each.value.secret_read_paths, ["ci/${each.key}/ssh"]) :
    "path \"secret/data/${p}\" {\n  capabilities = [\"read\"]\n}"
  ])
}

# --- Per-repo: the AppRole role ------------------------------------------------
# Non-expiring secret_id, CIDR-bound; short-lived issued tokens.
resource "vault_approle_auth_backend_role" "infra_ci" {
  for_each       = var.infra_ci_repos
  backend        = vault_auth_backend.approle[0].path
  role_name      = "${each.key}-ci"
  token_policies = [vault_policy.infra_ci[each.key].name]

  secret_id_num_uses    = 0
  secret_id_ttl         = 0
  token_ttl             = 1200 # 20m
  token_max_ttl         = 3600 # 1h
  token_num_uses        = 0
  secret_id_bound_cidrs = var.infra_ci_bound_cidrs
  token_bound_cidrs     = var.infra_ci_bound_cidrs
}

# role_id per repo — pair with an operator-pulled secret_id (see runbook).
output "infra_ci_role_ids" {
  description = "Map of infra-* repo => AppRole role_id (set as the repo's Forgejo role_id secret; pull the secret_id separately)."
  value       = { for k, r in vault_approle_auth_backend_role.infra_ci : k => r.role_id }
}
