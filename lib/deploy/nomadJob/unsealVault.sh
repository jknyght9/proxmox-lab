#!/usr/bin/env bash

# unsealVault - Unseal Vault using stored credentials
#
# Prerequisites:
#   - Vault deployed and running
#   - Credentials saved in VAULT_CREDENTIALS_FILE
#
# Globals read: VAULT_CREDENTIALS_FILE, VM_USER
# Arguments: None
# Returns: 0 on success (or already unsealed), 1 on failure

function unsealVault() {
  doing "Checking Vault seal status..."

  # Check if credentials file exists
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials file not found: $VAULT_CREDENTIALS_FILE"
    info "Deploy Vault first (option 8) to generate credentials."
    return 1
  fi

  # Read Vault address from credentials file
  local VAULT_ADDR
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ]; then
    error "Could not read vault_address from credentials file"
    return 1
  fi

  # Check current seal status
  local HEALTH_RESPONSE
  HEALTH_RESPONSE=$(curl -sf --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" 2>/dev/null)

  if [ -z "$HEALTH_RESPONSE" ]; then
    error "Cannot connect to Vault at $VAULT_ADDR"
    info "Ensure Vault is running: nomad job status vault"
    return 1
  fi

  local IS_SEALED
  IS_SEALED=$(echo "$HEALTH_RESPONSE" | jq -r '.sealed // true')

  if [ "$IS_SEALED" = "false" ]; then
    success "Vault is already unsealed"
    return 0
  fi

  # Vault is sealed, attempt to unseal
  doing "Vault is sealed, attempting to unseal..."

  local UNSEAL_KEY
  UNSEAL_KEY=$(jq -r '.unseal_key // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$UNSEAL_KEY" ]; then
    error "Could not read unseal_key from credentials file"
    return 1
  fi

  local UNSEAL_RESPONSE
  UNSEAL_RESPONSE=$(curl -sf --connect-timeout 5 --max-time 10 -X PUT \
    "${VAULT_ADDR}/v1/sys/unseal" \
    -H "Content-Type: application/json" \
    -d "{\"key\": \"$UNSEAL_KEY\"}" 2>&1)

  if echo "$UNSEAL_RESPONSE" | jq -e '.sealed == false' >/dev/null 2>&1; then
    success "Vault unsealed successfully"
    return 0
  else
    error "Failed to unseal Vault"
    echo "$UNSEAL_RESPONSE" | jq . 2>/dev/null || echo "$UNSEAL_RESPONSE"
    return 1
  fi
}

# Check if Vault is sealed
# Returns: 0 if unsealed, 1 if sealed or error
function isVaultSealed() {
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    return 1
  fi

  local VAULT_ADDR
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ]; then
    return 1
  fi

  local HEALTH_RESPONSE
  HEALTH_RESPONSE=$(curl -sf --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/sys/health" 2>/dev/null)

  if [ -z "$HEALTH_RESPONSE" ]; then
    return 1
  fi

  local IS_SEALED
  IS_SEALED=$(echo "$HEALTH_RESPONSE" | jq -r '.sealed // true')

  [ "$IS_SEALED" = "true" ]
}

# Get Vault address from credentials file
function getVaultAddress() {
  if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
    jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE"
  fi
}

# Get Vault root token from credentials file
function getVaultRootToken() {
  if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
    jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE"
  fi
}

# Get Nomad integration token from credentials file
function getNomadVaultToken() {
  if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
    jq -r '.nomad_token // empty' "$VAULT_CREDENTIALS_FILE"
  fi
}
