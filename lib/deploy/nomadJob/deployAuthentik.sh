#!/usr/bin/env bash

# deployAuthentikOnly - Deploy Authentik identity provider as a Nomad service
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Critical services deployed (DNS, CA)
#   - Traefik deployed for ingress
#   - Vault deployed for secrets management
#   - GlusterFS mounted at NOMAD_DATA_DIR
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, AUTHENTIK_DIR
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates Authentik storage directories on GlusterFS
#   - Generates PostgreSQL password and secret key if not present
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
    error "Vault is not deployed. Deploy Vault first (option 9)."
    return 1
  fi
  success "Vault is running"

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  # Create storage directories and generate secrets if they don't exist
  doing "Preparing Authentik storage and secrets..."

  if ! sshScript "$VM_USER" "$NOMAD_IP" <<'REMOTE_SCRIPT'
    AUTHENTIK_DIR="/srv/gluster/nomad-data/authentik"

    # Create required directories
    sudo mkdir -p "$AUTHENTIK_DIR"/{postgres,redis,media,templates,certs}

    # Generate PostgreSQL password if not exists
    if [ ! -f "$AUTHENTIK_DIR/.postgres_password" ]; then
      openssl rand -base64 24 | tr -d '\n' | sudo tee "$AUTHENTIK_DIR/.postgres_password" > /dev/null
      sudo chmod 600 "$AUTHENTIK_DIR/.postgres_password"
      echo "Generated new PostgreSQL password"
    fi

    # Generate Authentik secret key if not exists
    if [ ! -f "$AUTHENTIK_DIR/.secret_key" ]; then
      openssl rand -base64 36 | tr -d '\n' | sudo tee "$AUTHENTIK_DIR/.secret_key" > /dev/null
      sudo chmod 600 "$AUTHENTIK_DIR/.secret_key"
      echo "Generated new Authentik secret key"
    fi

    # Set ownership for volumes
    sudo chown -R 1000:1000 "$AUTHENTIK_DIR"
REMOTE_SCRIPT
  then
    error "Failed to prepare Authentik storage"
    return 1
  fi

  # Deploy Authentik using the generic Nomad job deployer
  if ! deployNomadJob "authentik" "nomad/jobs/authentik.nomad.hcl" "$AUTHENTIK_DIR"; then
    return 1
  fi

  # Update DNS records for authentik
  updateDNSRecords

  displayDeploymentSummary

  echo
  info "Authentik is starting up. This may take a minute..."
  info "Access Authentik at: https://auth.${DNS_POSTFIX}/ (via Traefik)"
  info "Or directly at: http://${NOMAD_IP}:9000/"
  info "First-time setup: Create admin account at /if/flow/initial-setup/"

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