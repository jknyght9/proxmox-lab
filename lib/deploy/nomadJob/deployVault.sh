#!/usr/bin/env bash

# deployVaultOnly - Deploy HashiCorp Vault as a Nomad service for secrets management
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Critical services deployed (DNS, CA)
#   - Traefik deployed (recommended for ingress)
#   - GlusterFS mounted at NOMAD_DATA_DIR
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, VAULT_DIR, VAULT_CREDENTIALS_FILE, SCRIPT_DIR
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates Vault storage directories on GlusterFS
#   - Initializes Vault if not already initialized
#   - Creates Vault policies and Nomad token role
#   - Saves credentials to VAULT_CREDENTIALS_FILE (crypto/vault-credentials.json)
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

  if ! sshScriptAdmin "$VM_USER" "$NOMAD_IP" <<'REMOTE_SCRIPT'
    VAULT_DIR="/srv/gluster/nomad-data/vault"

    # Create storage directory if it doesn't exist (preserve existing data!)
    if [ -d "$VAULT_DIR" ]; then
      echo "Vault storage directory exists, preserving data..."
    else
      echo "Creating Vault storage directory..."
      sudo mkdir -p "$VAULT_DIR"
    fi

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

    # Configure Vault policies, token role, and save credentials
    if ! configureVaultForNomad "$VAULT_IP" "$ROOT_TOKEN" "$UNSEAL_KEY"; then
      warn "Failed to configure Vault for Nomad - you can retry with menu option 11"
    else
      # Configure Nomad servers to use Vault
      if ! configureNomadVaultIntegration; then
        warn "Failed to configure Nomad-Vault integration - you can retry with menu option 11"
      fi
    fi

  else
    # Vault already initialized, check if sealed
    local IS_SEALED
    IS_SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed // true')

    if [ "$IS_SEALED" = "true" ]; then
      warn "Vault is sealed and requires unsealing."

      # Try to read unseal key from credentials file first
      local UNSEAL_KEY=""
      if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
        UNSEAL_KEY=$(jq -r '.unseal_key // empty' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
        if [ -n "$UNSEAL_KEY" ]; then
          doing "Using unseal key from $VAULT_CREDENTIALS_FILE..."
        fi
      fi

      # Fall back to prompting if no credentials file
      if [ -z "$UNSEAL_KEY" ]; then
        echo
        read -rsp "$(question "Enter your Vault unseal key: ")" UNSEAL_KEY
        echo
      fi

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
  info "Credentials: $VAULT_CREDENTIALS_FILE"
  echo
  warn "If Vault restarts, run 'Unseal Vault' (option 10) to unseal it."

  success "Vault deployment complete!"
}

# deployVaultWithCA - Deploy Vault and initialize PKI/ACME for internal CA
#
# Beta migration path: wraps deployVaultOnly and then runs initVaultPKI
# unconditionally. Safe to run against an already-initialized Vault because
# initVaultPKI checks for existing mounts/CAs before creating them.
#
# Requires crypto/vault-credentials.json to exist (written during first
# Vault init). If it doesn't, run option 6 first.
function deployVaultWithCA() {
  deployVaultOnly || return 1

  echo
  info "Running PKI/ACME initialization (idempotent)..."
  if ! initVaultPKI; then
    error "Vault PKI initialization failed"
    return 1
  fi

  success "Vault + PKI/ACME deployment complete!"
}

# Check if Vault is deployed as a Nomad job
function isVaultDeployed() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  local status
  status=$(sshRunAdmin "$VM_USER" "$nomad_ip" "nomad job status vault 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}

# configureVaultForNomad - Set up Vault policies, WIF, and save credentials
#
# Arguments:
#   $1 - Vault IP address
#   $2 - Root token
#   $3 - Unseal key
# Returns: 0 on success, 1 on failure
function configureVaultForNomad() {
  local VAULT_IP="$1"
  local ROOT_TOKEN="$2"
  local UNSEAL_KEY="$3"
  local VAULT_ADDR="http://${VAULT_IP}:8200"

  doing "Configuring Vault for Nomad integration..."

  # Upload and apply authentik policy
  doing "Creating authentik policy..."
  local AUTHENTIK_POLICY
  AUTHENTIK_POLICY=$(cat "$SCRIPT_DIR/nomad/vault-policies/authentik.hcl")

  if ! curl -sf --connect-timeout 5 --max-time 10 -X PUT "${VAULT_ADDR}/v1/sys/policies/acl/authentik" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"policy\": $(echo "$AUTHENTIK_POLICY" | jq -Rs .)}" > /dev/null; then
    error "Failed to create authentik policy"
    return 1
  fi
  success "Created authentik policy"

  # Save credentials to file (needed for unsealing and admin access)
  doing "Saving credentials to $VAULT_CREDENTIALS_FILE..."

  # Ensure crypto directory exists
  mkdir -p "$(dirname "$VAULT_CREDENTIALS_FILE")"

  local TIMESTAMP
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat > "$VAULT_CREDENTIALS_FILE" <<EOF
{
  "unseal_key": "$UNSEAL_KEY",
  "root_token": "$ROOT_TOKEN",
  "vault_address": "$VAULT_ADDR",
  "initialized_at": "$TIMESTAMP"
}
EOF

  # Set restrictive permissions
  chmod 600 "$VAULT_CREDENTIALS_FILE"

  success "Credentials saved to $VAULT_CREDENTIALS_FILE"

  # Configure Vault for Workload Identity Federation
  if ! configureVaultWIF; then
    error "Failed to configure Vault WIF"
    return 1
  fi

  # Initialize PKI secrets engine for certificate management
  if ! initVaultPKI; then
    warn "Failed to initialize PKI - you can retry with menu option"
  fi

  return 0
}

# initVaultPKI - Initialize Vault PKI secrets engine as a Certificate Authority
#
# Sets up a two-tier PKI with:
#   - pki/ - Root CA (10-year TTL)
#   - pki_int/ - Intermediate CA (5-year TTL) with ACME enabled
#
# The Intermediate CA handles all certificate issuance via ACME,
# replacing the step-ca LXC container.
#
# Arguments: None (reads from VAULT_CREDENTIALS_FILE)
# Returns: 0 on success, 1 on failure
function initVaultPKI() {
  doing "Initializing Vault PKI secrets engine..."

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

  # Get DNS postfix for CA naming
  local DNS_POSTFIX_LOCAL=""
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX_LOCAL=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
  fi
  if [ -z "$DNS_POSTFIX_LOCAL" ]; then
    DNS_POSTFIX_LOCAL="${DNS_POSTFIX:-lab.local}"
  fi

  # Check if PKI engines are already mounted
  local MOUNTS
  MOUNTS=$(curl -sf -H "X-Vault-Token: $ROOT_TOKEN" "${VAULT_ADDR}/v1/sys/mounts" 2>/dev/null || echo "{}")

  local PKI_EXISTS PKI_INT_EXISTS
  PKI_EXISTS=$(echo "$MOUNTS" | jq -e '."pki/"' > /dev/null 2>&1 && echo "true" || echo "false")
  PKI_INT_EXISTS=$(echo "$MOUNTS" | jq -e '."pki_int/"' > /dev/null 2>&1 && echo "true" || echo "false")

  # Enable Root PKI secrets engine
  if [ "$PKI_EXISTS" = "true" ]; then
    info "Root PKI engine already mounted at pki/"
  else
    doing "Enabling Root PKI secrets engine at pki/..."
    if ! curl -sf -X POST "${VAULT_ADDR}/v1/sys/mounts/pki" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"type": "pki", "description": "Root CA", "config": {"max_lease_ttl": "87600h"}}' > /dev/null; then
      error "Failed to enable Root PKI secrets engine"
      return 1
    fi
    success "Root PKI engine enabled"
  fi

  # Enable Intermediate PKI secrets engine
  if [ "$PKI_INT_EXISTS" = "true" ]; then
    info "Intermediate PKI engine already mounted at pki_int/"
  else
    doing "Enabling Intermediate PKI secrets engine at pki_int/..."
    if ! curl -sf -X POST "${VAULT_ADDR}/v1/sys/mounts/pki_int" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"type": "pki", "description": "Intermediate CA", "config": {"max_lease_ttl": "43800h"}}' > /dev/null; then
      error "Failed to enable Intermediate PKI secrets engine"
      return 1
    fi
    success "Intermediate PKI engine enabled"
  fi

  # Check if Root CA already exists
  local ROOT_CA_EXISTS
  ROOT_CA_EXISTS=$(curl -sf "${VAULT_ADDR}/v1/pki/ca/pem" 2>/dev/null | head -1 | grep -q "BEGIN CERTIFICATE" && echo "true" || echo "false")

  if [ "$ROOT_CA_EXISTS" = "true" ]; then
    info "Root CA already exists, skipping generation"
  else
    # Generate Root CA
    doing "Generating Root CA..."
    local ROOT_CA_CONFIG
    ROOT_CA_CONFIG=$(jq -n \
      --arg cn "Proxmox Lab Root CA" \
      --arg issuer "proxmox-lab-root" \
      '{
        common_name: $cn,
        issuer_name: $issuer,
        ttl: "87600h",
        key_type: "ec",
        key_bits: 256
      }')

    if ! curl -sf -X POST "${VAULT_ADDR}/v1/pki/root/generate/internal" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$ROOT_CA_CONFIG" > /dev/null; then
      error "Failed to generate Root CA"
      return 1
    fi
    success "Root CA generated"
  fi

  # Configure Root CA URLs
  doing "Configuring Root CA URLs..."
  local ROOT_URLS
  ROOT_URLS=$(jq -n \
    --arg vault_addr "$VAULT_ADDR" \
    '{
      issuing_certificates: [$vault_addr + "/v1/pki/ca"],
      crl_distribution_points: [$vault_addr + "/v1/pki/crl"]
    }')

  curl -sf -X POST "${VAULT_ADDR}/v1/pki/config/urls" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$ROOT_URLS" > /dev/null || true

  # Check if Intermediate CA already exists
  local INT_CA_EXISTS
  INT_CA_EXISTS=$(curl -sf "${VAULT_ADDR}/v1/pki_int/ca/pem" 2>/dev/null | head -1 | grep -q "BEGIN CERTIFICATE" && echo "true" || echo "false")

  if [ "$INT_CA_EXISTS" = "true" ]; then
    info "Intermediate CA already exists, skipping generation"
  else
    # Generate Intermediate CSR
    doing "Generating Intermediate CA CSR..."
    local INT_CSR_CONFIG
    INT_CSR_CONFIG=$(jq -n \
      --arg cn "Proxmox Lab Intermediate CA" \
      --arg issuer "proxmox-lab-intermediate" \
      '{
        common_name: $cn,
        issuer_name: $issuer,
        key_type: "ec",
        key_bits: 256
      }')

    local CSR_RESPONSE
    CSR_RESPONSE=$(curl -sf -X POST "${VAULT_ADDR}/v1/pki_int/intermediate/generate/internal" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$INT_CSR_CONFIG" 2>&1)

    local INT_CSR
    INT_CSR=$(echo "$CSR_RESPONSE" | jq -r '.data.csr // empty')

    if [ -z "$INT_CSR" ]; then
      error "Failed to generate Intermediate CSR"
      echo "$CSR_RESPONSE"
      return 1
    fi

    # Sign Intermediate with Root CA
    doing "Signing Intermediate CA with Root CA..."
    local SIGN_CONFIG
    SIGN_CONFIG=$(jq -n \
      --arg csr "$INT_CSR" \
      --arg cn "Proxmox Lab Intermediate CA" \
      '{
        csr: $csr,
        common_name: $cn,
        format: "pem_bundle",
        ttl: "43800h"
      }')

    local SIGN_RESPONSE
    SIGN_RESPONSE=$(curl -sf -X POST "${VAULT_ADDR}/v1/pki/root/sign-intermediate" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$SIGN_CONFIG" 2>&1)

    local INT_CERT
    INT_CERT=$(echo "$SIGN_RESPONSE" | jq -r '.data.certificate // empty')

    if [ -z "$INT_CERT" ]; then
      error "Failed to sign Intermediate CA"
      echo "$SIGN_RESPONSE"
      return 1
    fi

    # Import signed Intermediate certificate
    doing "Importing signed Intermediate CA..."
    local IMPORT_CONFIG
    IMPORT_CONFIG=$(jq -n --arg cert "$INT_CERT" '{certificate: $cert}')

    if ! curl -sf -X POST "${VAULT_ADDR}/v1/pki_int/intermediate/set-signed" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$IMPORT_CONFIG" > /dev/null; then
      error "Failed to import signed Intermediate CA"
      return 1
    fi
    success "Intermediate CA signed and imported"
  fi

  # Configure Intermediate CA URLs
  doing "Configuring Intermediate CA URLs..."
  local INT_URLS
  INT_URLS=$(jq -n \
    --arg vault_addr "$VAULT_ADDR" \
    '{
      issuing_certificates: [$vault_addr + "/v1/pki_int/ca"],
      crl_distribution_points: [$vault_addr + "/v1/pki_int/crl"]
    }')

  curl -sf -X POST "${VAULT_ADDR}/v1/pki_int/config/urls" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$INT_URLS" > /dev/null || true

  # Create ACME role for certificate issuance
  doing "Creating ACME certificate role..."
  local ACME_ROLE
  ACME_ROLE=$(jq -n \
    --arg domain "$DNS_POSTFIX_LOCAL" \
    '{
      allow_any_name: true,
      allow_ip_sans: true,
      allow_localhost: true,
      allow_bare_domains: true,
      allow_subdomains: true,
      allow_wildcard_certificates: true,
      enforce_hostnames: false,
      server_flag: true,
      client_flag: true,
      key_type: "ec",
      key_bits: 256,
      ttl: "2160h",
      max_ttl: "8760h"
    }')

  if ! curl -sf -X POST "${VAULT_ADDR}/v1/pki_int/roles/acme-certs" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$ACME_ROLE" > /dev/null; then
    error "Failed to create ACME role"
    return 1
  fi
  success "Created ACME certificate role 'acme-certs'"

  # Configure cluster path for ACME.
  #
  # This MUST point at Vault's direct HTTP API, not at Traefik
  # (https://vault.<domain>/...). Traefik consumes this PKI to obtain its
  # own cert — if the ACME directory URL goes back through Traefik,
  # Traefik can't bootstrap (chicken-and-egg: no cert yet, so the TLS
  # handshake to itself fails). Using the direct HTTP API on nomad01:8200
  # breaks the cycle. Vault is pinned to nomad01.
  local NOMAD01_IP
  NOMAD01_IP=$(jq -r '.external[] | select(.hostname == "nomad01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  if [ -z "$NOMAD01_IP" ] || [ "$NOMAD01_IP" = "null" ]; then
    # Fall back to whatever IP Vault reported during init
    NOMAD01_IP=$(echo "$VAULT_ADDR" | sed -E 's#https?://([^:/]+).*#\1#')
  fi

  doing "Configuring cluster path for ACME (http://${NOMAD01_IP}:8200)..."
  local CLUSTER_CONFIG
  CLUSTER_CONFIG=$(jq -n \
    --arg ip "$NOMAD01_IP" \
    '{
      path: ("http://" + $ip + ":8200/v1/pki_int")
    }')

  curl -sf -X POST "${VAULT_ADDR}/v1/pki_int/config/cluster" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$CLUSTER_CONFIG" > /dev/null || true

  # Enable ACME on Intermediate CA
  doing "Enabling ACME on Intermediate CA..."
  local ACME_CONFIG
  ACME_CONFIG=$(jq -n '{
    enabled: true,
    default_directory_policy: "sign-verbatim",
    allowed_roles: ["acme-certs"],
    allow_role_ext_key_usage: true
  }')

  if ! curl -sf -X POST "${VAULT_ADDR}/v1/pki_int/config/acme" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$ACME_CONFIG" > /dev/null; then
    error "Failed to enable ACME"
    return 1
  fi
  success "ACME enabled on Intermediate CA"

  # Verify ACME directory is accessible
  doing "Verifying ACME directory..."
  sleep 2
  local ACME_DIR
  ACME_DIR=$(curl -sf "${VAULT_ADDR}/v1/pki_int/acme/directory" 2>/dev/null || echo "")

  if echo "$ACME_DIR" | jq -e '.newAccount' > /dev/null 2>&1; then
    success "ACME directory accessible at ${VAULT_ADDR}/v1/pki_int/acme/directory"
  else
    warn "ACME directory not yet accessible - may need Traefik for HTTPS access"
  fi

  success "Vault PKI initialization complete!"

  echo
  info "Root CA: ${VAULT_ADDR}/v1/pki/ca/pem"
  info "Intermediate CA: ${VAULT_ADDR}/v1/pki_int/ca/pem"
  info "ACME Directory: http://${NOMAD01_IP}:8200/v1/pki_int/acme/directory (direct, bypasses Traefik)"
  echo

  return 0
}