# =============================================================================
# Pulse monitoring — read-only Proxmox API token (Option A)
#
# The token is MINTED here in the infrastructure layer (which already holds the
# privileged Proxmox provider) and written to Vault at secret/pulse. The Pulse
# Nomad job lives in the services layer and reads secret/pulse via Workload
# Identity Federation — it never sees the privileged Proxmox credential, only
# the read-only token value.
#
# All gated on var.deploy_pulse (default false), so this is inert on a vanilla
# deploy. The Vault write additionally requires a configured, reachable Vault
# with the "secret" kv-v2 mount (created by the services layer) — hence the
# local.vault_configured guard, matching the other Vault-dependent resources.
# =============================================================================

# Token-only user in the built-in PVE realm (no password needed for API tokens).
resource "proxmox_virtual_environment_user" "pulse" {
  count   = var.deploy_pulse ? 1 : 0
  user_id = "pulse@pve"
  comment = "Pulse monitoring (read-only) — managed by Terraform"
}

# Privilege-separated token: its rights come solely from the ACL below, not from
# the user — so it can only ever be read-only, even if the user is later granted
# more.
resource "proxmox_virtual_environment_user_token" "pulse_monitor" {
  count                 = var.deploy_pulse ? 1 : 0
  user_id               = proxmox_virtual_environment_user.pulse[0].user_id
  token_name            = "monitor"
  comment               = "Pulse read-only monitoring token — managed by Terraform"
  privileges_separation = true
}

# Grant the TOKEN the built-in read-only PVEAuditor role cluster-wide.
resource "proxmox_virtual_environment_acl" "pulse_auditor" {
  count     = var.deploy_pulse ? 1 : 0
  token_id  = proxmox_virtual_environment_user_token.pulse_monitor[0].id
  role_id   = "PVEAuditor"
  path      = "/"
  propagate = true
}

# Pulse local admin password (PULSE_AUTH_PASS), kept stable across applies.
resource "random_password" "pulse_admin" {
  count            = var.deploy_pulse ? 1 : 0
  length           = 24
  special          = true
  override_special = "!@#%^&*"
  keepers          = { service = "pulse" }
}

# Publish to Vault for the services-layer Pulse job (WIF-read at secret/pulse).
resource "vault_kv_secret_v2" "pulse" {
  count = var.deploy_pulse && local.vault_configured ? 1 : 0
  mount = "secret"
  name  = "pulse"
  data_json = jsonencode({
    # pve_token_* is what the operator pastes into Pulse's UI
    # (Settings -> Infrastructure) to add the Proxmox node(s) read-only.
    #   pve_token_id     -> Pulse "Token ID"     field: pulse@pve!monitor
    #   pve_token_secret -> Pulse "Token Value"  field: the bare UUID only
    # bpg's .value is the FULL "pulse@pve!monitor=<uuid>" string, which is
    # easy to paste whole into the Value field by mistake (=> auth fails), so
    # we also expose just the secret half. pve_token keeps the full string for
    # anyone building an Authorization: PVEAPIToken=<full> header.
    pve_token_id     = proxmox_virtual_environment_user_token.pulse_monitor[0].id
    pve_token        = proxmox_virtual_environment_user_token.pulse_monitor[0].value
    pve_token_secret = element(split("=", proxmox_virtual_environment_user_token.pulse_monitor[0].value), 1)
    # admin_password backs PULSE_AUTH_PASS for the Pulse web login.
    admin_password = random_password.pulse_admin[0].result
  })
}
