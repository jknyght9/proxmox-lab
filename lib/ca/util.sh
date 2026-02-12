#!/usr/bin/env bash

function generateCertificates() {
  doing "Setting up step-ca for certificate generation"
  STEPCA_DIR="terraform/lxc-step-ca/step-ca"
  if [ ! -d "$STEPCA_DIR" ]; then
    mkdir -p terraform/lxc-step-ca/step-ca
  fi
  docker compose run --rm -it step-ca
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

  # Wipe local CA files
  doing "Wiping local CA files..."
  rm -rf terraform/lxc-step-ca/step-ca/config
  rm -rf terraform/lxc-step-ca/step-ca/certs
  rm -rf terraform/lxc-step-ca/step-ca/secrets
  mkdir -p terraform/lxc-step-ca/step-ca

  # Regenerate certificates locally
  doing "Regenerating CA certificates..."
  docker compose run --rm -e FORCE_REGENERATE=1 step-ca
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