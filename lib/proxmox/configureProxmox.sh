#!/usr/bin/env bash

function checkProxmox() {
  header
  info "Requesting Proxmox information"

  if [[ -z "$PROXMOX_HOST" ]]; then
    read -rp "$(question "Enter the IP address or hostname of the Proxmox server: ")" PROXMOX_HOST
  fi

  if [[ -z "$PROXMOX_PASS" ]]; then
    read -s -rp "$(question "Enter the root password for $PROXMOX_HOST: ")" PROXMOX_PASS
    echo
  fi

  doing "Checking connectivity to $PROXMOX_HOST..."
  if ! ping -c 1 -W 2 "$PROXMOX_HOST" >/dev/null 2>&1; then
    error "Cannot reach $PROXMOX_HOST (ping failed)"
    exit 1
  fi

  doing "Testing SSH connection to $REMOTE_USER@$PROXMOX_HOST..."
  if ! sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "$REMOTE_USER@$PROXMOX_HOST" "echo SSH connection successful" >/dev/null 2>&1; then
    error "SSH connection failed. Check password or network."
    exit 1
  fi
  success "Successfully connected to $PROXMOX_HOST.\n"
}

function proxmoxLabInstall() {
  doing "Running Proxmox VE Lab Install Script..."
  scpTo "./proxmox/setup.sh" "$REMOTE_USER" "$PROXMOX_HOST" "/root/"
  ssh -i "$ENTERPRISE_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$PROXMOX_HOST" 'bash -c "chmod +x /root/setup.sh && /root/setup.sh"'
  success "Completed the lab installation script on $PROXMOX_HOST\n"
}

function proxmoxPostInstall() {
  # Check if we have cluster nodes loaded
  if [ ${#CLUSTER_NODES[@]} -eq 0 ]; then
    loadClusterInfo
  fi

  local node_count=${#CLUSTER_NODES[@]}
  local node_list=$(IFS=', '; echo "${CLUSTER_NODES[*]}")

  echo
  info "Proxmox VE Post-Installation Script"
  info "This script optimizes Proxmox settings, disables enterprise repo, etc."
  echo
  if [ "$node_count" -gt 1 ]; then
    info "Cluster nodes detected: $node_list"
    read -rp "$(question "Run post-install script on all $node_count cluster nodes? (y/N): ")" RUN_POST_SCRIPT
  else
    read -rp "$(question "Run post-install script on $PROXMOX_HOST? (y/N): ")" RUN_POST_SCRIPT
  fi

  if [[ "$RUN_POST_SCRIPT" =~ ^[Yy]$ ]]; then
    if [ ! -f "$ENTERPRISE_KEY_PATH" ]; then
      error "SSH private key not found at $ENTERPRISE_KEY_PATH"
      return 1
    fi

    for i in "${!CLUSTER_NODES[@]}"; do
      local node="${CLUSTER_NODES[$i]}"
      local ip="${CLUSTER_NODE_IPS[$i]}"

      doing "Running Proxmox VE Post-Install Script on $node ($ip)..."
      # Note: Using raw ssh here because we need -t for interactive script
      ssh -i "$ENTERPRISE_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$ip" \
        'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"' \
        && success "Completed post-installation on $node" \
        || warn "Post-installation may have failed on $node"
    done

    success "Post-installation complete on all nodes"
  else
    warn "Skipped running the post-install script"
  fi
}

function runProxmoxSetupOnAll() {
  doing "Running Proxmox setup on all cluster nodes..."

  # Load service passwords (includes template_password)
  loadServicePasswords || true

  # Build config JSON from cluster-info.json, injecting template_password
  local CONFIG
  CONFIG=$(jq --arg tp "${TEMPLATE_PASSWORD:-}" '. + {template_password: $tp}' "$CLUSTER_INFO_FILE")

  # Cluster-wide setup (run once on primary)
  local PRIMARY_IP="${CLUSTER_NODE_IPS[0]}"
  doing "Running cluster-wide Proxmox setup on ${CLUSTER_NODES[0]} ($PRIMARY_IP)..."

  scpTo "proxmox/setup.sh" "$REMOTE_USER" "${PRIMARY_IP}" "/tmp/proxmox-setup.sh"

  # Run setup and capture output for token extraction
  local SETUP_OUTPUT
  SETUP_OUTPUT=$(ssh -i "$ENTERPRISE_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@${PRIMARY_IP}" \
    "chmod +x /tmp/proxmox-setup.sh && /tmp/proxmox-setup.sh cluster-init '$CONFIG'" 2>&1) || true

  # Display the output
  echo "$SETUP_OUTPUT"

  # Extract and save API token credentials
  saveProxmoxCredentials "$SETUP_OUTPUT" "$PRIMARY_IP"

  # Per-node setup (run on each node) - pass config for storage/bridge settings
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    doing "Running node setup on $node ($ip)..."
    scpTo "proxmox/setup.sh" "$REMOTE_USER" "${ip}" "/tmp/proxmox-setup.sh"
    # Note: Using raw ssh here because we need -t for interactive script
    ssh -i "$ENTERPRISE_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@${ip}" \
      "chmod +x /tmp/proxmox-setup.sh && /tmp/proxmox-setup.sh node-setup '$CONFIG'"
  done

  success "Proxmox setup complete on all nodes"
}

function saveProxmoxCredentials() {
  local SETUP_OUTPUT="$1"
  local PROXMOX_IP="$2"
  local CREDS_FILE="$CRYPTO_DIR/proxmox-credentials.json"

  # Extract token info from output: PROXMOX_TOKEN_INFO:user!token:secret
  local TOKEN_LINE
  TOKEN_LINE=$(echo "$SETUP_OUTPUT" | grep "^PROXMOX_TOKEN_INFO:" | tail -1)

  if [ -z "$TOKEN_LINE" ]; then
    warn "Could not extract API token from Proxmox setup output"
    return 1
  fi

  local TOKEN_ID TOKEN_SECRET
  TOKEN_ID=$(echo "$TOKEN_LINE" | cut -d':' -f2)
  TOKEN_SECRET=$(echo "$TOKEN_LINE" | cut -d':' -f3)

  # Ensure crypto directory exists
  mkdir -p "$CRYPTO_DIR"

  # Build credentials JSON
  local API_URL="https://${PROXMOX_IP}:8006/api2/json"

  if [ "$TOKEN_SECRET" = "EXISTING" ]; then
    # Token exists but we don't have the secret
    if [ -f "$CREDS_FILE" ]; then
      info "API token exists on Proxmox; using existing credentials from $CREDS_FILE"
      return 0
    else
      warn "API token exists but no saved credentials found"
      warn "To regenerate: ssh to Proxmox and run: REGENERATE_TOKEN=true /tmp/proxmox-setup.sh cluster-init"
      # Create placeholder file
      jq -n \
        --arg url "$API_URL" \
        --arg token_id "$TOKEN_ID" \
        --arg token_secret "RETRIEVE_FROM_PROXMOX_OR_REGENERATE" \
        --arg note "Token exists but secret not available. Set REGENERATE_TOKEN=true to recreate." \
        '{
          proxmox_api_url: $url,
          proxmox_api_token_id: $token_id,
          proxmox_api_token_secret: $token_secret,
          note: $note,
          created_at: (now | todate)
        }' > "$CREDS_FILE"
      return 1
    fi
  elif [ "$TOKEN_SECRET" = "MANUAL" ] || [ "$TOKEN_SECRET" = "UNKNOWN" ]; then
    warn "Could not automatically capture API token secret"
    warn "Please manually update $CREDS_FILE with the token secret shown above"
    jq -n \
      --arg url "$API_URL" \
      --arg token_id "$TOKEN_ID" \
      --arg token_secret "PASTE_TOKEN_SECRET_HERE" \
      '{
        proxmox_api_url: $url,
        proxmox_api_token_id: $token_id,
        proxmox_api_token_secret: $token_secret,
        created_at: (now | todate)
      }' > "$CREDS_FILE"
    return 1
  else
    # We have the actual token secret
    jq -n \
      --arg url "$API_URL" \
      --arg token_id "$TOKEN_ID" \
      --arg token_secret "$TOKEN_SECRET" \
      '{
        proxmox_api_url: $url,
        proxmox_api_token_id: $token_id,
        proxmox_api_token_secret: $token_secret,
        created_at: (now | todate)
      }' > "$CREDS_FILE"

    chmod 600 "$CREDS_FILE"
    success "Proxmox API credentials saved to $CREDS_FILE"
    return 0
  fi
}