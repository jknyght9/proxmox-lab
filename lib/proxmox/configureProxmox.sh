#!/usr/bin/env bash

# Reset Proxmox API credentials - purge existing user/token/role and recreate
# Uses runBootstrap from lib/bootstrap.sh which handles token creation idempotently.
function resetProxmoxCredentials() {
  local CREDS_FILE="$CRYPTO_DIR/proxmox-credentials.json"
  local USER="hashicorp@pam"
  local TOKEN_ID="hashicorp-token"
  local ROLE="HashicorpBuild"

  cat <<EOF

############################################################################
Reset Proxmox API Credentials

This will:
1. Delete the existing hashicorp@pam user, token, and HashicorpBuild role
2. Remove the local credentials file (crypto/proxmox-credentials.json)
3. Re-run bootstrap to recreate everything and regenerate config files
############################################################################

EOF

  # Load cluster info
  if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    error "cluster-info.json not found. Run option 1 first."
    return 1
  fi
  loadClusterInfo

  read -rp "$(question "Proceed with credential reset? (y/N): ")" CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warn "Cancelled"
    return 0
  fi

  local PRIMARY_IP="${CLUSTER_NODE_IPS[0]}"

  # Step 1: Delete existing user, token, and role on Proxmox
  doing "Removing existing API user, token, and role from Proxmox..."
  sshRun "$REMOTE_USER" "$PRIMARY_IP" \
    "pveum user token remove $USER $TOKEN_ID 2>/dev/null || true; \
     pveum user delete $USER 2>/dev/null || true; \
     pveum role delete $ROLE 2>/dev/null || true"
  success "Removed existing Proxmox API resources"

  # Step 2: Remove local credentials file so bootstrap creates fresh ones
  doing "Removing local credentials file..."
  rm -f "$CREDS_FILE" 2>/dev/null || true
  success "Removed $CREDS_FILE"

  # Step 3: Re-run bootstrap (creates token, regenerates tfvars + packer vars)
  doing "Re-running bootstrap to recreate credentials..."
  runBootstrap || {
    error "Bootstrap failed"
    return 1
  }

  cat <<EOF

Proxmox API credentials have been reset successfully.

New credentials saved to: $CREDS_FILE
Terraform configuration: terraform/terraform.tfvars
Packer configuration:    packer/packer.auto.pkrvars.hcl

EOF
}
