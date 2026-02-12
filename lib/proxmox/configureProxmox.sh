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
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$PROXMOX_HOST" 'bash -c "chmod +x /root/setup.sh && /root/setup.sh"'
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
    if [ ! -f "$KEY_PATH" ]; then
      error "SSH private key not found at $KEY_PATH"
      return 1
    fi

    for i in "${!CLUSTER_NODES[@]}"; do
      local node="${CLUSTER_NODES[$i]}"
      local ip="${CLUSTER_NODE_IPS[$i]}"

      doing "Running Proxmox VE Post-Install Script on $node ($ip)..."
      # Note: Using raw ssh here because we need -t for interactive script
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$ip" \
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

  # Build config JSON from cluster-info.json (includes storage and bridge)
  local CONFIG
  CONFIG=$(cat "$CLUSTER_INFO_FILE")

  # Cluster-wide setup (run once on primary)
  local PRIMARY_IP="${CLUSTER_NODE_IPS[0]}"
  doing "Running cluster-wide Proxmox setup on ${CLUSTER_NODES[0]} ($PRIMARY_IP)..."

  scpTo "proxmox/setup.sh" "$REMOTE_USER" "${PRIMARY_IP}" "/tmp/proxmox-setup.sh"
  # Note: Using raw ssh here because we need -t for interactive script
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@${PRIMARY_IP}" \
    "chmod +x /tmp/proxmox-setup.sh && /tmp/proxmox-setup.sh cluster-init '$CONFIG'"

  # Per-node setup (run on each node) - pass config for storage/bridge settings
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    doing "Running node setup on $node ($ip)..."
    scpTo "proxmox/setup.sh" "$REMOTE_USER" "${ip}" "/tmp/proxmox-setup.sh"
    # Note: Using raw ssh here because we need -t for interactive script
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@${ip}" \
      "chmod +x /tmp/proxmox-setup.sh && /tmp/proxmox-setup.sh node-setup '$CONFIG'"
  done

  success "Proxmox setup complete on all nodes"
}