#!/usr/bin/env bash

# deployAuthentikOnly - Deploy Authentik identity provider as a Nomad service
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Critical services deployed (DNS, CA)
#   - Traefik deployed for ingress
#   - Vault deployed and unsealed with Nomad integration configured
#   - GlusterFS mounted at NOMAD_DATA_DIR
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, AUTHENTIK_DIR, VAULT_CREDENTIALS_FILE
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates Authentik storage directories on GlusterFS
#   - Stores secrets in Vault KV store
function deployAuthentikOnly() {
  cat <<EOF

############################################################################
Authentik Identity Provider Deployment

Deploying Authentik as a Nomad service for SSO and authentication.
Requires: Nomad cluster running, Traefik for ingress, Vault for secrets
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureCriticalServices || return 1
  ensureNomadCluster || return 1

  # Check Traefik is deployed (required for ingress)
  if ! isTraefikDeployed 2>/dev/null; then
    error "Traefik is not deployed. Deploy Traefik first (option 7)."
    return 1
  fi
  success "Traefik is running"

  # Check Vault is deployed (required for secrets management)
  if ! isVaultDeployed 2>/dev/null; then
    error "Vault is not deployed. Deploy Vault first (option 8)."
    return 1
  fi
  success "Vault is running"

  # Check credentials file exists
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials file not found: $VAULT_CREDENTIALS_FILE"
    info "Deploy Vault first (option 8) to generate credentials."
    return 1
  fi

  # Get Vault connection info
  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ] || [ -z "$ROOT_TOKEN" ]; then
    error "Could not read Vault credentials from $VAULT_CREDENTIALS_FILE"
    return 1
  fi

  # Check if Vault is sealed and unseal if needed
  doing "Checking Vault seal status..."
  if isVaultSealed; then
    warn "Vault is sealed, attempting to unseal..."
    if ! unsealVault; then
      error "Could not unseal Vault. Cannot deploy Authentik."
      info "Run 'Unseal Vault' (option 10) manually if needed."
      return 1
    fi
  fi
  success "Vault is unsealed"

  # Check if Nomad-Vault integration is configured
  if ! isNomadVaultConfigured 2>/dev/null; then
    error "Nomad-Vault integration is not configured."
    info "This should have been configured during Vault deployment."
    info "Run 'Configure Nomad-Vault integration' (option 11) to fix this."
    return 1
  fi
  success "Nomad-Vault integration is configured"

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  # Create storage directories (no secrets stored here anymore)
  doing "Preparing Authentik storage directories..."

  if ! sshScript "$VM_USER" "$NOMAD_IP" <<'REMOTE_SCRIPT'
    AUTHENTIK_DIR="/srv/gluster/nomad-data/authentik"

    # Create required directories (maps to /data/authentik/* in containers)
    sudo mkdir -p "$AUTHENTIK_DIR"/{postgres,redis,media,templates,certs}

    # Set ownership - postgres runs as root in our config, redis as redis (999)
    sudo chown -R root:root "$AUTHENTIK_DIR/postgres"
    sudo chown -R 999:999 "$AUTHENTIK_DIR/redis"
    sudo chown -R 1000:1000 "$AUTHENTIK_DIR/media" "$AUTHENTIK_DIR/templates" "$AUTHENTIK_DIR/certs"

    echo "Authentik storage directories prepared"
REMOTE_SCRIPT
  then
    error "Failed to prepare Authentik storage"
    return 1
  fi

  # Check if secrets already exist in Vault
  doing "Checking for existing secrets in Vault..."

  local SECRETS_EXIST=false
  local EXISTING_SECRETS
  # Use -s (silent) but not -f (fail) so we can check the response
  EXISTING_SECRETS=$(curl -s --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/secret/data/authentik" \
    -H "X-Vault-Token: $ROOT_TOKEN" 2>/dev/null || echo "{}")

  if echo "$EXISTING_SECRETS" | jq -e '.data.data.postgres_password' >/dev/null 2>&1; then
    SECRETS_EXIST=true
    success "Found existing secrets in Vault"
  fi

  if [ "$SECRETS_EXIST" = "false" ]; then
    doing "Generating and storing secrets in Vault..."

    # Generate new secrets
    local POSTGRES_PASSWORD SECRET_KEY
    POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
    SECRET_KEY=$(openssl rand -base64 36 | tr -d '\n')

    # Store secrets in Vault KV v2
    local SECRET_PAYLOAD
    SECRET_PAYLOAD=$(jq -n \
      --arg pg_pass "$POSTGRES_PASSWORD" \
      --arg secret_key "$SECRET_KEY" \
      '{data: {postgres_password: $pg_pass, secret_key: $secret_key}}')

    if ! curl -sf --connect-timeout 5 --max-time 10 -X POST \
      "${VAULT_ADDR}/v1/secret/data/authentik" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$SECRET_PAYLOAD" > /dev/null; then
      error "Failed to store secrets in Vault"
      return 1
    fi

    success "Secrets stored in Vault at secret/data/authentik"
  fi

  # Deploy Authentik - render only DNS_POSTFIX (secrets come from Vault)
  doing "Deploying Authentik to Nomad cluster..."

  # Load DNS_POSTFIX from cluster-info.json if not already set
  if [ -z "${DNS_POSTFIX:-}" ] || [ "$DNS_POSTFIX" = "null" ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    fi
  fi

  if [ -z "${DNS_POSTFIX:-}" ] || [ "$DNS_POSTFIX" = "null" ]; then
    error "DNS_POSTFIX not configured. Run initial setup first."
    return 1
  fi

  # Render template with DNS_POSTFIX (no secrets in file)
  export DNS_POSTFIX
  envsubst '${DNS_POSTFIX}' < "nomad/jobs/authentik.nomad.hcl" > "/tmp/authentik-rendered.nomad.hcl"

  # Copy to Nomad node
  scpTo "/tmp/authentik-rendered.nomad.hcl" "$VM_USER" "$NOMAD_IP" "/tmp/authentik.nomad.hcl"

  # Clean up local rendered file
  rm -f "/tmp/authentik-rendered.nomad.hcl"

  # Run the job
  if ! sshRun "$VM_USER" "$NOMAD_IP" "nomad job run /tmp/authentik.nomad.hcl"; then
    error "Failed to deploy authentik"
    return 1
  fi

  # Clean up remote rendered file
  sshRun "$VM_USER" "$NOMAD_IP" "rm -f /tmp/authentik.nomad.hcl"

  # Wait for deployment and show status
  doing "Waiting for authentik deployment..."
  sleep 5
  sshRun "$VM_USER" "$NOMAD_IP" "nomad job status authentik | head -25"

  success "authentik deployed successfully!"

  # Update DNS records for authentik
  updateDNSRecords

  displayDeploymentSummary

  echo
  info "Authentik is starting up. This may take a minute..."
  info "Access Authentik at: https://auth.${DNS_POSTFIX}/ (via Traefik)"
  info "Or directly at: http://${NOMAD_IP}:9000/"
  info "First-time setup: Create admin account at /if/flow/initial-setup/"
  echo
  info "Secrets are stored in Vault at: secret/data/authentik"

  success "Authentik deployment complete!"
}

# Check if Authentik is deployed as a Nomad job
function isAuthentikDeployed() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  local status
  status=$(sshRun "$VM_USER" "$nomad_ip" "nomad job status authentik 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}
