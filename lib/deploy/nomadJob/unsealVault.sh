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
  HEALTH_RESPONSE=$(curl -skf --connect-timeout 5 --max-time 10 \
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
  UNSEAL_RESPONSE=$(curl -skf --connect-timeout 5 --max-time 10 -X PUT \
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
  HEALTH_RESPONSE=$(curl -skf --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/sys/health" 2>/dev/null)

  if [ -z "$HEALTH_RESPONSE" ]; then
    return 1
  fi

  local IS_SEALED
  IS_SEALED=$(echo "$HEALTH_RESPONSE" | jq -r '.sealed // true')

  [ "$IS_SEALED" = "true" ]
}

# Walk every Vault instance in the Raft cluster and unseal each.
# Idempotent — already-unsealed instances return 200 with no change.
# Used after first init (the leader is unsealed but peers come up sealed)
# and after a TLS rollover (all 3 reseal on container restart).
#
# Arguments: $1 = protocol (http or https — defaults to https)
# Reads vault IPs from terraform.tfvars nomad_vm_configs.
function unsealAllVaults() {
  local proto="${1:-https}"
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Cannot unseal cluster — credentials file missing"
    return 1
  fi
  local UNSEAL_KEY
  UNSEAL_KEY=$(jq -r '.unseal_key // empty' "$VAULT_CREDENTIALS_FILE")
  if [ -z "$UNSEAL_KEY" ]; then
    error "unseal_key missing from $VAULT_CREDENTIALS_FILE"
    return 1
  fi

  # Pull Nomad VM IPs from Layer 1 tfvars (where bootstrap wrote them)
  local vault_ips
  vault_ips=$(awk '/nomad_vm_configs/,/^}/' "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null \
    | grep -oE '"nomad[0-9]+".*ip = "[^"]+"' \
    | grep -oE 'ip = "[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$vault_ips" ]; then
    error "Could not parse nomad_vm_configs from terraform.tfvars"
    return 1
  fi

  doing "Unsealing all Vault instances (Raft cluster)..."
  local all_ok=true
  for ip in $vault_ips; do
    local addr="${proto}://${ip}:8200"
    # Wait briefly for this instance to be reachable
    local reachable=false
    for i in {1..30}; do
      if curl -sk --connect-timeout 2 --max-time 3 \
           "${addr}/v1/sys/seal-status" >/dev/null 2>&1; then
        reachable=true
        break
      fi
      sleep 2
    done
    if [ "$reachable" != true ]; then
      warn "  ${ip}: not reachable, skipping"
      all_ok=false
      continue
    fi

    # Already unsealed?
    local sealed
    sealed=$(curl -sk --max-time 5 "${addr}/v1/sys/seal-status" 2>/dev/null \
              | jq -r '.sealed // true')
    if [ "$sealed" = "false" ]; then
      info "  ${ip}: already unsealed"
      continue
    fi

    # POST unseal, retry up to 3 times
    local opened=false
    for attempt in 1 2 3; do
      curl -sk --max-time 10 -X PUT "${addr}/v1/sys/unseal" \
        -H "Content-Type: application/json" \
        -d "{\"key\": \"$UNSEAL_KEY\"}" >/dev/null 2>&1
      sleep 2
      sealed=$(curl -sk --max-time 5 "${addr}/v1/sys/seal-status" 2>/dev/null \
                | jq -r '.sealed // true')
      if [ "$sealed" = "false" ]; then
        opened=true
        break
      fi
      sleep 3
    done
    if [ "$opened" = true ]; then
      info "  ${ip}: ✓ unsealed"
    else
      error "  ${ip}: failed to unseal after 3 attempts"
      all_ok=false
    fi
  done

  if [ "$all_ok" = true ]; then
    success "All Vault instances unsealed"
    return 0
  else
    warn "Some Vault instances are still sealed — see above"
    return 1
  fi
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
