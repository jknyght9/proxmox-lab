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

    # Create required directories
    sudo mkdir -p "$VAULT_DIR"/{file,config}
    sudo chmod 700 "$VAULT_DIR"

    echo "Vault storage directories created"
REMOTE_SCRIPT
  then
    error "Failed to prepare Vault storage"
    return 1
  fi

  # Deploy Vault using the generic Nomad job deployer
  if ! deployNomadJob "vault" "nomad/jobs/vault.nomad.hcl" "$VAULT_DIR"; then
    return 1
  fi

  # Wait for Vault to start
  doing "Waiting for Vault to start..."
  sleep 10

  # Check Vault status and initialize if needed
  doing "Checking Vault initialization status..."

  local VAULT_STATUS
  VAULT_STATUS=$(curl -s "http://$NOMAD_IP:8200/v1/sys/health" 2>/dev/null || echo '{"initialized": false}')

  local IS_INITIALIZED
  IS_INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')

  if [ "$IS_INITIALIZED" = "false" ]; then
    doing "Initializing Vault (1 key share for home lab simplicity)..."

    local INIT_RESPONSE
    INIT_RESPONSE=$(curl -s -X PUT "http://$NOMAD_IP:8200/v1/sys/init" \
      -H "Content-Type: application/json" \
      -d '{"secret_shares": 1, "secret_threshold": 1}')

    local UNSEAL_KEY ROOT_TOKEN
    UNSEAL_KEY=$(echo "$INIT_RESPONSE" | jq -r '.keys[0]')
    ROOT_TOKEN=$(echo "$INIT_RESPONSE" | jq -r '.root_token')

    if [ -z "$UNSEAL_KEY" ] || [ "$UNSEAL_KEY" = "null" ]; then
      error "Failed to initialize Vault"
      echo "$INIT_RESPONSE"
      return 1
    fi

    # Store unseal key and root token on GlusterFS
    doing "Storing Vault credentials on GlusterFS..."
    sshRun "$VM_USER" "$NOMAD_IP" "echo '$UNSEAL_KEY' | sudo tee $VAULT_DIR/.unseal_key > /dev/null; echo '$ROOT_TOKEN' | sudo tee $VAULT_DIR/.root_token > /dev/null; sudo chmod 600 $VAULT_DIR/.unseal_key; sudo chmod 600 $VAULT_DIR/.root_token"

    success "Vault initialized successfully"

    # Unseal Vault
    doing "Unsealing Vault..."
    curl -s -X PUT "http://$NOMAD_IP:8200/v1/sys/unseal" \
      -H "Content-Type: application/json" \
      -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null

    success "Vault unsealed"

    # Enable KV secrets engine
    doing "Enabling KV v2 secrets engine..."
    sleep 2
    curl -s -X POST "http://$NOMAD_IP:8200/v1/sys/mounts/secret" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"type": "kv", "options": {"version": "2"}}' > /dev/null

    success "KV v2 secrets engine enabled at secret/"

  else
    # Vault already initialized, check if sealed
    local IS_SEALED
    IS_SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed // true')

    if [ "$IS_SEALED" = "true" ]; then
      doing "Vault is sealed. Attempting auto-unseal..."

      # Try to read unseal key from GlusterFS
      local UNSEAL_KEY
      UNSEAL_KEY=$(sshRun "$VM_USER" "$NOMAD_IP" "sudo cat $VAULT_DIR/.unseal_key 2>/dev/null" || echo "")

      if [ -n "$UNSEAL_KEY" ]; then
        curl -s -X PUT "http://$NOMAD_IP:8200/v1/sys/unseal" \
          -H "Content-Type: application/json" \
          -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null
        success "Vault unsealed using stored key"
      else
        warn "Could not find unseal key at /srv/gluster/nomad-data/vault/.unseal_key"
        warn "You will need to unseal Vault manually"
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
  info "Or directly at: http://${NOMAD_IP}:8200/"
  info "Root token stored at: /srv/gluster/nomad-data/vault/.root_token"
  info "Unseal key stored at: /srv/gluster/nomad-data/vault/.unseal_key"
  echo
  warn "SECURITY NOTE: For production, use proper auto-unseal (AWS KMS, etc.)"
  warn "and store root token securely. This setup is for home lab use."

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