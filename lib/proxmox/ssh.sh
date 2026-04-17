#!/usr/bin/env bash

function distributeSSHKeys() {
  doing "Distributing SSH keys to all cluster nodes..."

  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
  local enterprise_pubkey_content
  enterprise_pubkey_content=$(cat "$ENTERPRISE_PUBKEY_PATH")

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    doing "  $node ($ip): Installing SSH keys..."

    # Create .ssh directory
    if ! sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS "$REMOTE_USER@$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>&1; then
      warn "  $node ($ip): Failed to create .ssh directory (check password)"
      continue
    fi

    # Copy enterprise public key file (for Proxmox node administration)
    if ! sshpass -p "$PROXMOX_PASS" scp $SSH_OPTS "$ENTERPRISE_PUBKEY_PATH" "$REMOTE_USER@$ip:/root/.ssh/$ENTERPRISE_KEY_NAME.pub" 2>&1; then
      warn "  $node ($ip): Failed to copy enterprise public key file"
      continue
    fi

    # Copy admin public key file (for VM/container cloud-init templates)
    if ! sshpass -p "$PROXMOX_PASS" scp $SSH_OPTS "$ADMIN_PUBKEY_PATH" "$REMOTE_USER@$ip:/root/.ssh/$ADMIN_KEY_NAME.pub" 2>&1; then
      warn "  $node ($ip): Failed to copy admin public key file"
      # Continue anyway - this is not critical for Proxmox node access
    fi

    # Add enterprise key to authorized_keys if not already present
    # Only enterprise key goes on Proxmox nodes - admin key is for VMs/containers only
    if ! sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS "$REMOTE_USER@$ip" \
      "grep -qF '${enterprise_pubkey_content}' ~/.ssh/authorized_keys 2>/dev/null \
        || (echo '${enterprise_pubkey_content}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)" 2>&1; then
      warn "  $node ($ip): Failed to add key to authorized_keys"
      continue
    fi

    success "  $node ($ip): Keys installed"
  done

  success "SSH keys distributed to all nodes"
}

function generateSSHKeys() {
    doing "Generating SSH keys for deployment..."
    mkdir -p "$CRYPTO_DIR"

    local keys_exist=false
    if [[ -f "$ENTERPRISE_KEY_PATH" ]] || [[ -f "$ADMIN_KEY_PATH" ]]; then
      keys_exist=true
    fi

    # Check if keys already exist
    if [ "$keys_exist" = "true" ]; then
      warn "SSH keys already exist in $CRYPTO_DIR"
      [ -f "$ENTERPRISE_KEY_PATH" ] && info "  - Enterprise key: $ENTERPRISE_KEY_PATH"
      [ -f "$ADMIN_KEY_PATH" ] && info "  - Admin key: $ADMIN_KEY_PATH"
      read -rp "$(question "Do you want to overwrite them? [y/N]: ")" confirm
      [[ ! "$confirm" =~ ^[Yy]$ ]] && info "Continuing without changes..." && return 0
    fi

    # Generate enterprise key (for Proxmox node administration)
    doing "Generating enterprise key (labenterpriseadmin) for Proxmox nodes..."
    ssh-keygen -t ed25519 -f "$ENTERPRISE_KEY_PATH" -C "labenterpriseadmin" -N "" || {
      error "Enterprise SSH key generation failed."
      exit 1
    }
    chmod 600 "$ENTERPRISE_KEY_PATH"
    chmod 644 "$ENTERPRISE_KEY_PATH.pub"

    # Generate admin key (for VM/container administration)
    doing "Generating admin key (labadmin) for VMs and containers..."
    ssh-keygen -t ed25519 -f "$ADMIN_KEY_PATH" -C "labadmin" -N "" || {
      error "Admin SSH key generation failed."
      exit 1
    }
    chmod 600 "$ADMIN_KEY_PATH"
    chmod 644 "$ADMIN_KEY_PATH.pub"

    success "SSH key pairs generated:"
    echo "    Enterprise (Proxmox nodes):"
    echo "      Private key: $ENTERPRISE_KEY_PATH"
    echo "      Public key:  $ENTERPRISE_PUBKEY_PATH"
    echo "    Admin (VMs/containers):"
    echo "      Private key: $ADMIN_KEY_PATH"
    echo "      Public key:  $ADMIN_PUBKEY_PATH"
}

function installSSHKeys() {
  doing "Installing SSH public keys on primary Proxmox node..."
  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

  sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS "$REMOTE_USER@$PROXMOX_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

  # Copy enterprise public key file (for Proxmox node administration)
  sshpass -p "$PROXMOX_PASS" scp $SSH_OPTS "$ENTERPRISE_PUBKEY_PATH" "$REMOTE_USER@$PROXMOX_HOST:/root/.ssh/$ENTERPRISE_KEY_NAME.pub"

  # Copy admin public key file (for VM/container cloud-init templates)
  sshpass -p "$PROXMOX_PASS" scp $SSH_OPTS "$ADMIN_PUBKEY_PATH" "$REMOTE_USER@$PROXMOX_HOST:/root/.ssh/$ADMIN_KEY_NAME.pub"

  # Add enterprise key to authorized_keys (only enterprise key on Proxmox nodes - admin key is for VMs/containers)
  sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS "$REMOTE_USER@$PROXMOX_HOST" \
    "grep -qxF '$(cat "$ENTERPRISE_PUBKEY_PATH")' ~/.ssh/authorized_keys 2>/dev/null \
      || (echo '$(cat "$ENTERPRISE_PUBKEY_PATH")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)"
  success "SSH public keys installed successfully on $PROXMOX_HOST.\n"
}
