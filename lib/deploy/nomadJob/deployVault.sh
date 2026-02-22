#!/usr/bin/env bash

# deployVaultOnly - Deploy HashiCorp Vault as a Nomad service for secrets management
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Critical services deployed (DNS, CA)
#   - Traefik deployed (recommended for ingress)
#   - GlusterFS mounted at NOMAD_DATA_DIR
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, VAULT_DIR
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates Vault storage directories on GlusterFS
#   - Initializes Vault if not already initialized
#   - Stores unseal key and root token at VAULT_DIR/.unseal_key and .root_token
function deployVaultOnly() {
  cat <<EOF

############################################################################
Vault Secrets Manager Deployment

Deploying HashiCorp Vault as a Nomad service for centralized secrets management.
Requires: Nomad cluster running, Traefik for ingress (recommended)
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureCriticalServices || return 1
  ensureNomadCluster || return 1

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  # Create storage directories
  doing "Preparing Vault storage directories..."

  if ! sshScript "$VM_USER" "$NOMAD_IP" <<'REMOTE_SCRIPT'
    VAULT_DIR="/srv/gluster/nomad-data/vault"

    # Clean up any stale data from previous deployments
    if [ -d "$VAULT_DIR" ]; then
      echo "Cleaning up previous Vault data..."
      sudo rm -rf "$VAULT_DIR"
    fi

    # Create storage directory with permissive permissions
    sudo mkdir -p "$VAULT_DIR"
    sudo chmod 777 "$VAULT_DIR"

    # Verify directory is writable
    if sudo touch "$VAULT_DIR/.write_test" && sudo rm "$VAULT_DIR/.write_test"; then
      echo "Vault storage directory prepared and writable"
    else
      echo "ERROR: Vault storage directory is not writable"
      exit 1
    fi
REMOTE_SCRIPT
  then
    error "Failed to prepare Vault storage"
    return 1
  fi

  # Deploy Vault using the generic Nomad job deployer
  if ! deployNomadJob "vault" "nomad/jobs/vault.nomad.hcl" "$VAULT_DIR"; then
    return 1
  fi

  # Wait for Vault to start and find which node it's running on
  # Use uninitcode=200&sealedcode=200 to accept uninitialized/sealed Vault as "running"
  doing "Waiting for Vault to start (checking all Nomad nodes)..."

  local VAULT_IP=""
  local VAULT_READY=false
  local ALL_NOMAD_IPS
  ALL_NOMAD_IPS=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json | cut -d'/' -f1)

  for attempt in {1..30}; do
    for ip in $ALL_NOMAD_IPS; do
      # Accept any response (even 501) as long as Vault is responding
      if curl -s --connect-timeout 2 --max-time 3 "http://$ip:8200/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1; then
        VAULT_IP="$ip"
        VAULT_READY=true
        break 2
      fi
    done
    sleep 2
  done

  if [ -z "$VAULT_IP" ]; then
    VAULT_IP="$NOMAD_IP"  # Fallback for error messages
  fi

  info "Vault running on: $VAULT_IP"

  if [ "$VAULT_READY" = "false" ]; then
    error "Vault did not become responsive within 60 seconds"
    info "Check Nomad logs: nomad alloc logs -job vault"
    return 1
  fi

  # Check Vault status and initialize if needed
  doing "Checking Vault initialization status..."

  local VAULT_STATUS
  VAULT_STATUS=$(curl -sf --connect-timeout 5 --max-time 10 "http://$VAULT_IP:8200/v1/sys/health" 2>/dev/null || echo '{"initialized": false}')

  local IS_INITIALIZED
  IS_INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')

  if [ "$IS_INITIALIZED" = "false" ]; then
    doing "Initializing Vault (1 key share for home lab simplicity)..."

    local INIT_RESPONSE
    INIT_RESPONSE=$(curl -sf --connect-timeout 5 --max-time 30 -X PUT "http://$VAULT_IP:8200/v1/sys/init" \
      -H "Content-Type: application/json" \
      -d '{"secret_shares": 1, "secret_threshold": 1}' 2>&1)

    local UNSEAL_KEY ROOT_TOKEN
    UNSEAL_KEY=$(echo "$INIT_RESPONSE" | jq -r '.keys[0]')
    ROOT_TOKEN=$(echo "$INIT_RESPONSE" | jq -r '.root_token')

    if [ -z "$UNSEAL_KEY" ] || [ "$UNSEAL_KEY" = "null" ]; then
      error "Failed to initialize Vault"
      echo "$INIT_RESPONSE"
      return 1
    fi

    success "Vault initialized successfully"

    # Display credentials - user must save these securely
    echo
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                        VAULT CREDENTIALS - SAVE THESE NOW                    ║"
    echo "║                                                                              ║"
    echo "║  These credentials will NOT be displayed again and are NOT stored on disk.   ║"
    echo "║  Store them in a password manager or other secure location.                  ║"
    echo "╠══════════════════════════════════════════════════════════════════════════════╣"
    echo "║                                                                              ║"
    printf "║  %-74s  ║\n" "UNSEAL KEY:"
    printf "║  %-74s  ║\n" "$UNSEAL_KEY"
    echo "║                                                                              ║"
    printf "║  %-74s  ║\n" "ROOT TOKEN:"
    printf "║  %-74s  ║\n" "$ROOT_TOKEN"
    echo "║                                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo
    read -rp "$(question "Have you saved these credentials securely? [y/N]: ")" SAVED_CREDS
    if [[ ! "$SAVED_CREDS" =~ ^[Yy]$ ]]; then
      warn "Please save the credentials above before continuing!"
      read -rp "$(question "Press Enter when ready...")"
    fi

    # Unseal Vault
    doing "Unsealing Vault..."
    curl -sf --connect-timeout 5 --max-time 10 -X PUT "http://$VAULT_IP:8200/v1/sys/unseal" \
      -H "Content-Type: application/json" \
      -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null

    success "Vault unsealed"

    # Enable KV secrets engine
    doing "Enabling KV v2 secrets engine..."
    sleep 2
    curl -sf --connect-timeout 5 --max-time 10 -X POST "http://$VAULT_IP:8200/v1/sys/mounts/secret" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"type": "kv", "options": {"version": "2"}}' > /dev/null 2>&1 || true

    success "KV v2 secrets engine enabled at secret/"

  else
    # Vault already initialized, check if sealed
    local IS_SEALED
    IS_SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed // true')

    if [ "$IS_SEALED" = "true" ]; then
      warn "Vault is sealed and requires unsealing."
      echo
      read -rsp "$(question "Enter your Vault unseal key: ")" UNSEAL_KEY
      echo

      if [ -n "$UNSEAL_KEY" ]; then
        local UNSEAL_RESPONSE
        UNSEAL_RESPONSE=$(curl -sf --connect-timeout 5 --max-time 10 -X PUT "http://$VAULT_IP:8200/v1/sys/unseal" \
          -H "Content-Type: application/json" \
          -d "{\"key\": \"$UNSEAL_KEY\"}" 2>&1)

        if echo "$UNSEAL_RESPONSE" | jq -e '.sealed == false' >/dev/null 2>&1; then
          success "Vault unsealed successfully"
        else
          error "Failed to unseal Vault. Check your unseal key."
          return 1
        fi
      else
        error "No unseal key provided"
        return 1
      fi
    else
      success "Vault is already initialized and unsealed"
    fi
  fi

  # Update DNS records for vault
  updateDNSRecords

  displayDeploymentSummary

  echo
  info "Vault is running at: https://vault.${DNS_POSTFIX}/ (via Traefik)"
  info "Or directly at: http://${VAULT_IP}:8200/"
  echo
  warn "IMPORTANT: Vault credentials are NOT stored on disk."
  warn "If Vault restarts, you will need to unseal it with your saved unseal key."
  warn "If you lose your credentials, you will need to redeploy Vault from scratch."

  success "Vault deployment complete!"
}

# Check if Vault is deployed as a Nomad job
function isVaultDeployed() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  local status
  status=$(sshRun "$VM_USER" "$nomad_ip" "nomad job status vault 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}