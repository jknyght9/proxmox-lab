#!/usr/bin/env bash

function distributeSSHKeys() {
  doing "Distributing SSH keys to all cluster nodes..."

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Skip if this is the primary (already has keys from installSSHKeys)
    if [ "$ip" = "$PROXMOX_HOST" ]; then
      info "  $node ($ip): Primary - already configured"
      continue
    fi

    doing "  $node ($ip): Installing SSH keys..."
    sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null
    sshpass -p "$PROXMOX_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$PUBKEY_PATH" "$REMOTE_USER@$ip:/root/.ssh/$KEY_NAME.pub" 2>/dev/null
    sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
      "grep -qxF '$(cat "$PUBKEY_PATH")' ~/.ssh/authorized_keys 2>/dev/null \
        || (echo '$(cat "$PUBKEY_PATH")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)" 2>/dev/null
    success "  $node ($ip): Keys installed"
  done

  success "SSH keys distributed to all nodes"
}

function generateSSHKeys() {
    doing "Generating SSH keys for deployment..."
    mkdir -p "$CRYPTO_DIR"

    # Check if key already exists
    if [[ -f "$KEY_PATH" ]]; then
      warn "SSH key already exists at $KEY_PATH"
      read -rp "$(question "Do you want to overwrite it? [y/N]: ")" confirm
      [[ ! "$confirm" =~ ^[Yy]$ ]] && info "Continuing without changes..." && return 0
    fi

    # Generate key (always runs if key doesn't exist or confirmed overwrite)
    ssh-keygen -t ed25519 -f "$KEY_PATH" -C "lab-deploy" -N "" || {
      error "SSH key generation failed."
      exit 1
    }
    chmod 600 "$KEY_PATH"
    chmod 600 "$KEY_PATH".pub

    success "SSH key pair generated:"
    echo "    Private key: $KEY_PATH"
    echo "    Public key:  $KEY_PATH.pub"
}

function installSSHKeys() {
  doing "Installing SSH public key..."
  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

  sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS "$REMOTE_USER@$PROXMOX_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  sshpass -p "$PROXMOX_PASS" scp $SSH_OPTS "$PUBKEY_PATH" "$REMOTE_USER@$PROXMOX_HOST":/root/.ssh/$KEY_NAME.pub
  sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS "$REMOTE_USER@$PROXMOX_HOST" \
    "grep -qxF '$(cat "$PUBKEY_PATH")' ~/.ssh/authorized_keys 2>/dev/null \
      || (echo '$(cat "$PUBKEY_PATH")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)"
  success "Public key installed successfully on $PROXMOX_HOST.\n"
}