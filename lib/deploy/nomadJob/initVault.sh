#!/usr/bin/env bash

# initVault - Initialize and unseal Vault, save credentials
#
# This is the one imperative step that can't be Terraformed:
# Vault must be initialized to generate the unseal key and root token,
# and these must be captured and saved to disk.
#
# After this runs, Layer 2 (terraform/services/) can configure
# everything else inside Vault declaratively.
#
# Globals read: VAULT_CREDENTIALS_FILE, SCRIPT_DIR
# Arguments: $1 - Vault IP (default: first Nomad node from hosts.json)
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Initializes Vault (1 key share, 1 threshold)
#   - Unseals Vault
#   - Saves unseal_key, root_token, vault_address to VAULT_CREDENTIALS_FILE
#   - Writes terraform/services/terraform.tfvars with vault/nomad addresses

function initAndUnsealVault() {
  local VAULT_IP="${1:-}"

  if [ -z "$VAULT_IP" ]; then
    VAULT_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
  fi

  if [ -z "$VAULT_IP" ]; then
    error "Could not determine Vault IP. Provide it as argument or ensure hosts.json exists."
    return 1
  fi

  # Determine protocol — check if Vault is already serving HTTPS
  local VAULT_PROTO="http"
  if curl -sk --connect-timeout 2 --max-time 3 "https://$VAULT_IP:8200/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1; then
    VAULT_PROTO="https"
  fi

  local VAULT_ADDR="${VAULT_PROTO}://${VAULT_IP}:8200"
  doing "Checking Vault at $VAULT_ADDR..."

  # Check init status
  local VAULT_STATUS
  VAULT_STATUS=$(curl -skf --connect-timeout 5 --max-time 10 "${VAULT_ADDR}/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" 2>/dev/null || echo '{"initialized": false}')

  local IS_INITIALIZED
  IS_INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')

  if [ "$IS_INITIALIZED" = "false" ]; then
    doing "Initializing Vault (1 key share for home lab)..."

    local INIT_RESPONSE
    INIT_RESPONSE=$(curl -skf --connect-timeout 5 --max-time 30 -X PUT "${VAULT_ADDR}/v1/sys/init" \
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

    success "Vault initialized"

    # Unseal
    doing "Unsealing Vault..."
    curl -skf --connect-timeout 5 --max-time 10 -X PUT "${VAULT_ADDR}/v1/sys/unseal" \
      -H "Content-Type: application/json" \
      -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null

    success "Vault unsealed"

    # Save credentials
    mkdir -p "$(dirname "$VAULT_CREDENTIALS_FILE")"
    cat > "$VAULT_CREDENTIALS_FILE" <<EOF
{
  "unseal_key": "$UNSEAL_KEY",
  "root_token": "$ROOT_TOKEN",
  "vault_address": "$VAULT_ADDR",
  "initialized_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "$VAULT_CREDENTIALS_FILE"
    success "Credentials saved to $VAULT_CREDENTIALS_FILE"

  else
    info "Vault already initialized"

    # Check if sealed, unseal if needed
    local IS_SEALED
    IS_SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed // true')

    if [ "$IS_SEALED" = "true" ]; then
      doing "Vault is sealed, attempting to unseal..."
      local UNSEAL_KEY=""
      if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
        UNSEAL_KEY=$(jq -r '.unseal_key // empty' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
      fi
      if [ -z "$UNSEAL_KEY" ]; then
        read -rsp "$(question "Enter your Vault unseal key: ")" UNSEAL_KEY
        echo
      fi
      curl -skf --connect-timeout 5 --max-time 10 -X PUT "${VAULT_ADDR}/v1/sys/unseal" \
        -H "Content-Type: application/json" \
        -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null
      success "Vault unsealed"
    else
      success "Vault is already unsealed"
    fi

    # Ensure credentials file exists with current address
    if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
      warn "No credentials file found — cannot update vault_address"
      warn "If you have the root token, create $VAULT_CREDENTIALS_FILE manually"
      return 1
    fi

    # Update vault_address if it changed (e.g., http -> https)
    local STORED_ADDR
    STORED_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
    if [ "$STORED_ADDR" != "$VAULT_ADDR" ] && [ -n "$STORED_ADDR" ]; then
      doing "Updating vault_address: $STORED_ADDR → $VAULT_ADDR"
      local tmp; tmp=$(mktemp)
      jq --arg addr "$VAULT_ADDR" '.vault_address = $addr' "$VAULT_CREDENTIALS_FILE" > "$tmp" && mv "$tmp" "$VAULT_CREDENTIALS_FILE"
      chmod 600 "$VAULT_CREDENTIALS_FILE"
    fi
  fi

  # Read credentials for tfvars generation
  local ROOT_TOKEN VAULT_ADDR_FINAL
  ROOT_TOKEN=$(jq -r '.root_token' "$VAULT_CREDENTIALS_FILE")
  VAULT_ADDR_FINAL=$(jq -r '.vault_address' "$VAULT_CREDENTIALS_FILE")

  # Write Layer 2 tfvars
  doing "Writing terraform/services/terraform.tfvars..."
  local SERVICES_TFVARS="${SCRIPT_DIR}/terraform/services/terraform.tfvars"
  local NOMAD_ADDR="http://${VAULT_IP}:4646"

  # Get DNS server IP — try hosts.json, then dns_primary from tfvars, then derive from network
  local DNS_SERVER_IP=""
  DNS_SERVER_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
  if [ -z "$DNS_SERVER_IP" ]; then
    DNS_SERVER_IP=$(sed -n 's/^dns_primary_ipv4.*=.*"\(.*\)"/\1/p' "${SCRIPT_DIR}/terraform/terraform.tfvars" 2>/dev/null)
  fi

  # Get Nomad node IPs from Layer 1 terraform.tfvars vm_configs or state
  local NOMAD_IPS_HCL=""
  # Try terraform output first
  NOMAD_IPS_HCL=$(docker compose run --rm -T terraform output -json 2>/dev/null | jq -r '.hosts.value.nomad // {} | to_entries[] | "  \(.key) = \"\(.value.ip)\""' 2>/dev/null) || true

  # Fallback: parse from vm_configs defaults in variables.tf
  if [ -z "$NOMAD_IPS_HCL" ]; then
    NOMAD_IPS_HCL=$(sed -n 's/.*"\(nomad[0-9]*\)".*ip = "\([^"]*\)".*/  \1 = "\2"/p' "${SCRIPT_DIR}/terraform/vm-nomad/variables.tf" 2>/dev/null)
  fi

  cat > "$SERVICES_TFVARS" <<EOF
# =============================================================================
# Layer 2 — Auto-generated after Vault init
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# =============================================================================

vault_address   = "${VAULT_ADDR_FINAL}"
vault_token     = "${ROOT_TOKEN}"
nomad_address   = "${NOMAD_ADDR}"
dns_postfix     = "${DNS_POSTFIX}"
dns_server_ip   = "${DNS_SERVER_IP}"
network_gateway = "$(jq -r '.network.external.gateway // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)"
network_cidr    = "$(jq -r '.network.external.cidr // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)"

nomad_node_ips = {
${NOMAD_IPS_HCL}
}

ssh_admin_private_key_file      = "/crypto/labadmin"
ssh_admin_public_key_file       = "/crypto/labadmin.pub"
ssh_enterprise_private_key_file = "/crypto/labenterpriseadmin"

# Service toggles — set to true to deploy
deploy_traefik = true
EOF

  chmod 600 "$SERVICES_TFVARS"
  success "terraform/services/terraform.tfvars written"

  # Also update Layer 1 vault.auto.tfvars and nomad_address
  cat > "${SCRIPT_DIR}/terraform/vault.auto.tfvars" <<EOF
vault_address = "${VAULT_ADDR_FINAL}"
vault_token   = "${ROOT_TOKEN}"
nomad_address = "${NOMAD_ADDR}"
EOF
  chmod 600 "${SCRIPT_DIR}/terraform/vault.auto.tfvars"
  success "terraform/vault.auto.tfvars written"

  echo
  success "Vault is ready. Run Layer 2 to configure services:"
  info "  docker compose run --rm -it terraform-services apply"
}
