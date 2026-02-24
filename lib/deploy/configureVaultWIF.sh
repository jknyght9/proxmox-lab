#!/usr/bin/env bash

# configureVaultWIF - Configure Vault for Workload Identity Federation with Nomad
#
# This sets up JWT auth in Vault to trust Nomad's workload identities.
# More secure than legacy tokens - no secrets stored on Nomad nodes.
#
# Prerequisites:
#   - Vault deployed and unsealed
#   - Nomad cluster running
#
# Globals read: VAULT_CREDENTIALS_FILE
# Arguments: None
# Returns: 0 on success, 1 on failure

function configureVaultWIF() {
  doing "Configuring Vault for Workload Identity Federation..."

  # Check credentials file exists
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials file not found: $VAULT_CREDENTIALS_FILE"
    return 1
  fi

  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ] || [ -z "$ROOT_TOKEN" ]; then
    error "Could not read Vault credentials"
    return 1
  fi

  # Get first Nomad node for JWKS URL
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  if [ -z "$NOMAD_IP" ]; then
    error "Could not find Nomad node IP"
    return 1
  fi

  # Verify Nomad JWKS endpoint is accessible
  doing "Verifying Nomad JWKS endpoint..."
  local JWKS_URL="http://${NOMAD_IP}:4646/.well-known/jwks.json"

  if ! curl -sf --connect-timeout 5 --max-time 10 "$JWKS_URL" > /dev/null 2>&1; then
    error "Cannot reach Nomad JWKS endpoint at $JWKS_URL"
    return 1
  fi
  success "Nomad JWKS endpoint accessible"

  # Enable JWT auth method at path 'jwt-nomad' (Nomad's default expected path)
  doing "Enabling JWT auth method in Vault at path 'jwt-nomad'..."

  # Check if already enabled
  local AUTH_LIST
  AUTH_LIST=$(curl -sf -H "X-Vault-Token: $ROOT_TOKEN" \
    "${VAULT_ADDR}/v1/sys/auth" 2>/dev/null || echo "{}")

  if echo "$AUTH_LIST" | jq -e '."jwt-nomad/"' > /dev/null 2>&1; then
    info "JWT auth method already enabled at jwt-nomad"
  else
    if ! curl -sf -X POST "${VAULT_ADDR}/v1/sys/auth/jwt-nomad" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"type": "jwt", "description": "Nomad Workload Identity"}' > /dev/null; then
      error "Failed to enable JWT auth method"
      return 1
    fi
    success "JWT auth method enabled at jwt-nomad"
  fi

  # Configure JWT auth to trust Nomad's JWKS
  doing "Configuring JWT auth to trust Nomad..."

  local JWT_CONFIG
  JWT_CONFIG=$(jq -n \
    --arg jwks_url "$JWKS_URL" \
    '{
      jwks_url: $jwks_url,
      default_role: "nomad-workloads"
    }')

  if ! curl -sf -X POST "${VAULT_ADDR}/v1/auth/jwt-nomad/config" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$JWT_CONFIG" > /dev/null; then
    error "Failed to configure JWT auth"
    return 1
  fi
  success "JWT auth configured to trust Nomad JWKS"

  # Create the authentik role
  doing "Creating Vault role for Authentik workloads..."

  local AUTHENTIK_ROLE
  AUTHENTIK_ROLE=$(cat <<'ROLE_JSON'
{
  "role_type": "jwt",
  "bound_audiences": ["vault.io"],
  "user_claim": "/nomad_job_id",
  "user_claim_json_pointer": true,
  "claim_mappings": {
    "nomad_namespace": "nomad_namespace",
    "nomad_job_id": "nomad_job_id",
    "nomad_task": "nomad_task"
  },
  "token_type": "service",
  "token_policies": ["authentik"],
  "token_period": "1h",
  "token_ttl": "1h",
  "bound_claims": {
    "nomad_job_id": "authentik"
  }
}
ROLE_JSON
)

  if ! curl -sf -X POST "${VAULT_ADDR}/v1/auth/jwt-nomad/role/authentik" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$AUTHENTIK_ROLE" > /dev/null; then
    error "Failed to create authentik role"
    return 1
  fi
  success "Created Vault role 'authentik'"

  # Create a general nomad-workloads role for future services
  doing "Creating general Vault role for Nomad workloads..."

  local GENERAL_ROLE
  GENERAL_ROLE=$(cat <<'ROLE_JSON'
{
  "role_type": "jwt",
  "bound_audiences": ["vault.io"],
  "user_claim": "/nomad_job_id",
  "user_claim_json_pointer": true,
  "claim_mappings": {
    "nomad_namespace": "nomad_namespace",
    "nomad_job_id": "nomad_job_id",
    "nomad_task": "nomad_task"
  },
  "token_type": "service",
  "token_policies": ["nomad-workloads"],
  "token_period": "1h",
  "token_ttl": "1h"
}
ROLE_JSON
)

  if ! curl -sf -X POST "${VAULT_ADDR}/v1/auth/jwt-nomad/role/nomad-workloads" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$GENERAL_ROLE" > /dev/null; then
    error "Failed to create nomad-workloads role"
    return 1
  fi
  success "Created Vault role 'nomad-workloads'"

  # Create a general nomad-workloads policy (minimal, for future use)
  doing "Creating nomad-workloads policy..."

  local WORKLOADS_POLICY='# General policy for Nomad workloads
# Add paths here as needed for new services

path "secret/data/{{identity.entity.aliases.auth_jwt_*.metadata.nomad_job_id}}/*" {
  capabilities = ["read"]
}
'

  if ! curl -sf -X PUT "${VAULT_ADDR}/v1/sys/policies/acl/nomad-workloads" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"policy\": $(echo "$WORKLOADS_POLICY" | jq -Rs .)}" > /dev/null; then
    error "Failed to create nomad-workloads policy"
    return 1
  fi
  success "Created nomad-workloads policy"

  success "Vault WIF configuration complete!"

  echo
  info "Vault is now configured to trust Nomad workload identities"
  info "JWKS URL: $JWKS_URL"
  info "Roles created: authentik, nomad-workloads"

  return 0
}
