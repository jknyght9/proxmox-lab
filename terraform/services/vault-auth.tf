# =============================================================================
# Vault JWT Auth — Nomad Workload Identity Federation
# Replaces: configureVaultWIF.sh
# =============================================================================

resource "vault_jwt_auth_backend" "nomad" {
  path               = "jwt-nomad"
  type               = "jwt"
  description        = "Nomad Workload Identity"
  jwks_url           = "http://${local.nomad01_ip}:4646/.well-known/jwks.json"
  default_role       = "nomad-workloads"
}

# Default role for all Nomad workloads
resource "vault_jwt_auth_backend_role" "nomad_workloads" {
  backend        = vault_jwt_auth_backend.nomad.path
  role_name      = "nomad-workloads"
  role_type      = "jwt"
  bound_audiences = ["vault.io"]
  user_claim     = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type     = "service"
  token_policies = ["nomad-workloads"]
  token_period   = 3600
  token_ttl      = 3600
}

# Per-service roles — each bound to a specific Nomad job_id
resource "vault_jwt_auth_backend_role" "authentik" {
  count          = var.deploy_authentik ? 1 : 0
  backend        = vault_jwt_auth_backend.nomad.path
  role_name      = "authentik"
  role_type      = "jwt"
  bound_audiences = ["vault.io"]
  user_claim     = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type     = "service"
  token_policies = ["authentik"]
  token_period   = 3600
  token_ttl      = 3600
  bound_claims   = { nomad_job_id = "authentik" }
}

resource "vault_jwt_auth_backend_role" "samba_dc" {
  count          = var.deploy_samba_dc ? 1 : 0
  backend        = vault_jwt_auth_backend.nomad.path
  role_name      = "samba-dc"
  role_type      = "jwt"
  bound_audiences = ["vault.io"]
  user_claim     = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type     = "service"
  token_policies = ["samba-dc"]
  token_period   = 3600
  token_ttl      = 3600
  bound_claims   = { nomad_job_id = "samba-dc" }
}

resource "vault_jwt_auth_backend_role" "backup" {
  count          = var.deploy_backup ? 1 : 0
  backend        = vault_jwt_auth_backend.nomad.path
  role_name      = "backup"
  role_type      = "jwt"
  bound_audiences = ["vault.io"]
  user_claim     = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type     = "service"
  token_policies = ["backup"]
  token_period   = 3600
  token_ttl      = 3600
  bound_claims   = { nomad_job_id = "backup" }
}

resource "vault_jwt_auth_backend_role" "lam" {
  count          = var.deploy_lam ? 1 : 0
  backend        = vault_jwt_auth_backend.nomad.path
  role_name      = "lam"
  role_type      = "jwt"
  bound_audiences = ["vault.io"]
  user_claim     = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type     = "service"
  token_policies = ["lam"]
  token_period   = 3600
  token_ttl      = 3600
  bound_claims   = { nomad_job_id = "lam" }
}

resource "vault_jwt_auth_backend_role" "tailscale" {
  count          = var.deploy_tailscale ? 1 : 0
  backend        = vault_jwt_auth_backend.nomad.path
  role_name      = "tailscale"
  role_type      = "jwt"
  bound_audiences = ["vault.io"]
  user_claim     = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type     = "service"
  token_policies = ["tailscale"]
  token_period   = 3600
  token_ttl      = 3600
  bound_claims   = { nomad_job_id = "tailscale" }
}
