#!/usr/bin/env bash

# pushCertificatesToStepCA - Push locally-generated CA certs to step-ca LXC container
#
# After Terraform creates the step-ca container (with packages installed and
# directories created), this function pushes the locally-generated certificates,
# configuration, and secrets to the container and starts the step-ca service.
#
# The certificates are generated locally via Docker (generateCertificates)
# because `step ca init` requires a TTY which Terraform provisioners don't provide.
#
# Prerequisites:
#   - hosts.json with step-ca entry
#   - Local certs in terraform/lxc-step-ca/step-ca/
#   - ADMIN_KEY_PATH set
#
# Arguments: None
# Returns: 0 on success, 1 on failure
function pushCertificatesToStepCA() {
  local STEPCA_DIR="terraform/lxc-step-ca/step-ca"
  local CA_IP

  # Get step-ca IP from hosts.json
  if [ ! -f "hosts.json" ]; then
    error "hosts.json not found. Cannot determine step-ca IP."
    return 1
  fi

  CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  if [ -z "$CA_IP" ] || [ "$CA_IP" = "null" ]; then
    error "step-ca not found in hosts.json"
    return 1
  fi

  # Verify local certificates exist
  if [ ! -f "$STEPCA_DIR/certs/root_ca.crt" ]; then
    error "Local CA certificates not found in $STEPCA_DIR"
    error "Run generateCertificates first"
    return 1
  fi

  doing "Pushing certificates to step-ca container at $CA_IP..."

  # Wait for container to be reachable
  local retries=0
  while ! sshRunAdmin "root" "$CA_IP" "echo ready" >/dev/null 2>&1; do
    retries=$((retries + 1))
    if [ $retries -gt 30 ]; then
      error "step-ca container not reachable after 30 attempts"
      return 1
    fi
    echo "  Waiting for container to be reachable... ($retries/30)"
    sleep 2
  done

  # Push certificates
  doing "  Copying certificates..."
  scpToAdmin "$STEPCA_DIR/certs/root_ca.crt" "root" "$CA_IP" "/etc/step-ca/certs/"
  scpToAdmin "$STEPCA_DIR/certs/intermediate_ca.crt" "root" "$CA_IP" "/etc/step-ca/certs/"

  # Push configuration
  doing "  Copying configuration..."
  scpToAdmin "$STEPCA_DIR/config/ca.json" "root" "$CA_IP" "/etc/step-ca/config/"
  scpToAdmin "$STEPCA_DIR/config/defaults.json" "root" "$CA_IP" "/etc/step-ca/config/"

  # Push secrets
  doing "  Copying secrets..."
  scpToAdmin "$STEPCA_DIR/secrets/intermediate_ca_key" "root" "$CA_IP" "/etc/step-ca/secrets/"
  scpToAdmin "$STEPCA_DIR/secrets/password_file" "root" "$CA_IP" "/etc/step-ca/secrets/"
  scpToAdmin "$STEPCA_DIR/secrets/root_ca_key" "root" "$CA_IP" "/etc/step-ca/secrets/"

  # Set proper permissions and start the service
  doing "  Setting permissions and starting step-ca service..."
  sshRunAdmin "root" "$CA_IP" "chmod 600 /etc/step-ca/secrets/* /etc/step-ca/certs/* && systemctl start step-ca"

  # Verify service is running
  if sshRunAdmin "root" "$CA_IP" "systemctl is-active step-ca" >/dev/null 2>&1; then
    success "step-ca service started successfully"
  else
    error "step-ca service failed to start"
    sshRunAdmin "root" "$CA_IP" "journalctl -u step-ca --no-pager -n 20" 2>/dev/null || true
    return 1
  fi

  return 0
}

function generateCertificates() {
  doing "Setting up step-ca for certificate generation"
  STEPCA_DIR="terraform/lxc-step-ca/step-ca"
  if [ ! -d "$STEPCA_DIR" ]; then
    mkdir -p terraform/lxc-step-ca/step-ca
  fi
  docker compose run --rm -it step-ca

  # Fix permissions - Docker creates files as root, making them unreadable
  # by the user running the script (needed for pushCertificatesToStepCA)
  if [ -d "$STEPCA_DIR" ]; then
    doing "Fixing certificate directory permissions..."
    sudo chown -R "$(id -u):$(id -g)" "$STEPCA_DIR"
  fi

  success "Certificate generation complete.\n"
}

function regenerateCA() {
  warn "This will DESTROY the existing Certificate Authority and generate new credentials."
  warn "All existing certificates signed by this CA will become INVALID."
  echo
  read -rp "$(question "Are you sure you want to regenerate the CA? [y/N]: ")" CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    info "CA regeneration cancelled"
    return 0
  fi

  # Wipe local CA files (may need sudo if owned by root from previous Docker run)
  doing "Wiping local CA files..."
  sudo rm -rf terraform/lxc-step-ca/step-ca/config
  sudo rm -rf terraform/lxc-step-ca/step-ca/certs
  sudo rm -rf terraform/lxc-step-ca/step-ca/secrets
  mkdir -p terraform/lxc-step-ca/step-ca

  # Regenerate certificates locally
  doing "Regenerating CA certificates..."
  docker compose run --rm -e FORCE_REGENERATE=1 step-ca

  # Fix permissions - Docker creates files as root
  doing "Fixing certificate directory permissions..."
  sudo chown -R "$(id -u):$(id -g)" terraform/lxc-step-ca/step-ca

  success "CA certificates regenerated locally"

  # Check if step-ca LXC exists and offer to redeploy
  if [ -f hosts.json ]; then
    CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    if [ -n "$CA_IP" ] && [ "$CA_IP" != "null" ]; then
      read -rp "$(question "Redeploy step-ca LXC container with new certificates? [Y/n]: ")" REDEPLOY
      REDEPLOY=${REDEPLOY:-Y}
      if [[ "$REDEPLOY" =~ ^[Yy]$ ]]; then
        doing "Redeploying step-ca LXC container..."
        docker compose run --rm -it terraform apply \
          -target=module.step-ca \
          -replace="module.step-ca.proxmox_lxc.step-ca"
        success "step-ca LXC redeployed"

        # Push new certificates to the container
        if ! pushCertificatesToStepCA; then
          error "Failed to push certificates to step-ca container"
          return 1
        fi
      fi
    fi
  fi

  success "CA regeneration complete"

  # Update root certificates on Proxmox nodes
  read -rp "$(question "Update root certificates on Proxmox nodes now? [Y/n]: ")" UPDATE_CERTS
  UPDATE_CERTS=${UPDATE_CERTS:-Y}
  if [[ "$UPDATE_CERTS" =~ ^[Yy]$ ]]; then
    updateRootCertificates
  else
    info "Remember to run 'Update root certificates' to install the new CA on Proxmox nodes"
  fi
}