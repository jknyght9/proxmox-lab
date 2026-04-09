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
  # Note: As of Authentik 2025.10, Redis is no longer needed
  doing "Preparing Authentik storage directories..."

  if ! sshScriptAdmin "$VM_USER" "$NOMAD_IP" <<'REMOTE_SCRIPT'
    AUTHENTIK_DIR="/srv/gluster/nomad-data/authentik"

    # Create required directories
    # - postgres: PostgreSQL data (now handles all caching/sessions)
    # - data: Authentik data directory (media, templates, certs)
    sudo mkdir -p "$AUTHENTIK_DIR"/{postgres,data/media}

    # Set ownership - postgres runs as root, authentik runs as 1000
    sudo chown -R root:root "$AUTHENTIK_DIR/postgres"
    sudo chown -R 1000:1000 "$AUTHENTIK_DIR/data"

    echo "Authentik storage directories prepared"
REMOTE_SCRIPT
  then
    error "Failed to prepare Authentik storage"
    return 1
  fi

  # Check existing secrets in Vault and add any missing ones
  doing "Checking secrets in Vault..."

  local EXISTING_SECRETS
  EXISTING_SECRETS=$(curl -s --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/secret/data/authentik" \
    -H "X-Vault-Token: $ROOT_TOKEN" 2>/dev/null || echo "{}")

  # Extract existing values (empty string if not present)
  local POSTGRES_PASSWORD SECRET_KEY ADMIN_PASSWORD ADMIN_EMAIL
  POSTGRES_PASSWORD=$(echo "$EXISTING_SECRETS" | jq -r '.data.data.postgres_password // empty' 2>/dev/null)
  SECRET_KEY=$(echo "$EXISTING_SECRETS" | jq -r '.data.data.secret_key // empty' 2>/dev/null)
  ADMIN_PASSWORD=$(echo "$EXISTING_SECRETS" | jq -r '.data.data.admin_password // empty' 2>/dev/null)
  ADMIN_EMAIL=$(echo "$EXISTING_SECRETS" | jq -r '.data.data.admin_email // empty' 2>/dev/null)

  local SECRETS_UPDATED=false

  # Generate missing postgres_password
  if [ -z "$POSTGRES_PASSWORD" ]; then
    POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
    info "Generated new postgres_password"
    SECRETS_UPDATED=true
  else
    success "Found existing postgres_password"
  fi

  # Generate missing secret_key
  if [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(openssl rand -base64 36 | tr -d '\n')
    info "Generated new secret_key"
    SECRETS_UPDATED=true
  else
    success "Found existing secret_key"
  fi

  # Generate missing admin_password
  if [ -z "$ADMIN_PASSWORD" ]; then
    local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"
    if [ -f "$PASSWORDS_FILE" ] && jq -e '.authentik_admin_password' "$PASSWORDS_FILE" >/dev/null 2>&1; then
      ADMIN_PASSWORD=$(jq -r '.authentik_admin_password' "$PASSWORDS_FILE")
      info "Using admin password from service-passwords.json"
    else
      ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 24)
      # Save to service-passwords.json if it exists
      if [ -f "$PASSWORDS_FILE" ]; then
        local tmp_file=$(mktemp)
        jq --arg pass "$ADMIN_PASSWORD" '. + {authentik_admin_password: $pass}' "$PASSWORDS_FILE" > "$tmp_file" && mv "$tmp_file" "$PASSWORDS_FILE"
        chmod 600 "$PASSWORDS_FILE"
      fi
      info "Generated new admin_password"
    fi
    SECRETS_UPDATED=true
  else
    success "Found existing admin_password"
  fi

  # Set admin_email if missing
  if [ -z "$ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="admin@${DNS_POSTFIX}"
    info "Set admin_email to $ADMIN_EMAIL"
    SECRETS_UPDATED=true
  else
    success "Found existing admin_email"
  fi

  # Store secrets in Vault if any were generated/updated
  if [ "$SECRETS_UPDATED" = "true" ]; then
    doing "Storing secrets in Vault..."

    local SECRET_PAYLOAD
    SECRET_PAYLOAD=$(jq -n \
      --arg pg_pass "$POSTGRES_PASSWORD" \
      --arg secret_key "$SECRET_KEY" \
      --arg admin_pass "$ADMIN_PASSWORD" \
      --arg admin_email "$ADMIN_EMAIL" \
      '{data: {postgres_password: $pg_pass, secret_key: $secret_key, admin_password: $admin_pass, admin_email: $admin_email}}')

    if ! curl -skf --connect-timeout 5 --max-time 10 -X POST \
      "${VAULT_ADDR}/v1/secret/data/authentik" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$SECRET_PAYLOAD" > /dev/null; then
      error "Failed to store secrets in Vault"
      return 1
    fi

    success "Secrets stored in Vault at secret/data/authentik"
  else
    success "All secrets already present in Vault"
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
  scpToAdmin "/tmp/authentik-rendered.nomad.hcl" "$VM_USER" "$NOMAD_IP" "/tmp/authentik.nomad.hcl"

  # Clean up local rendered file
  rm -f "/tmp/authentik-rendered.nomad.hcl"

  # Run the job
  if ! sshRunAdmin "$VM_USER" "$NOMAD_IP" "nomad job run /tmp/authentik.nomad.hcl"; then
    error "Failed to deploy authentik"
    return 1
  fi

  # Clean up remote rendered file
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "rm -f /tmp/authentik.nomad.hcl"

  # Wait for deployment and show status
  doing "Waiting for authentik deployment..."
  sleep 5
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "nomad job status authentik | head -25"

  success "authentik deployed successfully!"

  # Update DNS records for authentik
  updateDNSRecords

  displayDeploymentSummary

  # Get admin password for display
  local DISPLAY_ADMIN_PASS=""
  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"
  if [ -f "$PASSWORDS_FILE" ]; then
    DISPLAY_ADMIN_PASS=$(jq -r '.authentik_admin_password // empty' "$PASSWORDS_FILE")
  fi

  echo
  info "Authentik is starting up. This may take a minute..."
  info "Access Authentik at: https://auth.${DNS_POSTFIX}/ (via Traefik)"
  info "Or directly at: http://${NOMAD_IP}:9000/"
  echo
  info "Admin credentials:"
  info "  Username: akadmin"
  info "  Password: ${DISPLAY_ADMIN_PASS:-<check Vault at secret/data/authentik>}"
  info "  Email: admin@${DNS_POSTFIX}"
  echo
  info "Secrets stored in Vault at: secret/data/authentik"
  info "Password also saved in: $PASSWORDS_FILE"

  success "Authentik deployment complete!"
}

# Check if Authentik is deployed as a Nomad job
function isAuthentikDeployed() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  local status
  status=$(sshRunAdmin "$VM_USER" "$nomad_ip" "nomad job status authentik 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}
