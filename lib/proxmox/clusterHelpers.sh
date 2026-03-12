#!/usr/bin/env bash

# checkClusterConnectivity - Verify internet connectivity on all Proxmox nodes
#
# Tests that each node can reach the internet (required for package downloads
# during LXC provisioning). Reports DNS configuration for failing nodes.
#
# Globals read: KEY_PATH, REMOTE_USER, CLUSTER_NODES, CLUSTER_NODE_IPS
# Arguments: None
# Returns: 0 if all nodes have connectivity, 1 if any node fails
function checkClusterConnectivity() {
  doing "Checking internet connectivity on Proxmox nodes..."

  local failed_nodes=()
  local dns_configs=()

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Test internet connectivity (try to reach a reliable endpoint)
    if ! sshRun "$REMOTE_USER" "$ip" "curl -s --connect-timeout 5 https://install.pi-hole.net >/dev/null 2>&1 || ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1" 2>/dev/null; then
      failed_nodes+=("$node ($ip)")

      # Get DNS configuration for this node
      local dns_info
      dns_info=$(sshRun "$REMOTE_USER" "$ip" "echo 'resolv.conf:'; cat /etc/resolv.conf; echo ''; echo 'pvesh DNS:'; pvesh get /nodes/$node/dns --output-format json 2>/dev/null | jq -r 'to_entries[] | \"  \\(.key): \\(.value)\"'" 2>/dev/null)
      dns_configs+=("=== $node ($ip) ===\n$dns_info")
    else
      success "  $node ($ip): OK"
    fi
  done

  if [ ${#failed_nodes[@]} -gt 0 ]; then
    echo
    error "Internet connectivity check FAILED on the following nodes:"
    for node in "${failed_nodes[@]}"; do
      echo "  - $node"
    done

    echo
    warn "Current DNS configuration on failed nodes:"
    echo
    for config in "${dns_configs[@]}"; do
      echo -e "$config"
      echo
    done

    cat <<EOF

#############################################################################
CONNECTIVITY ERROR

The Proxmox nodes listed above cannot reach the internet. This is required
for downloading packages during LXC container provisioning.

Common causes:
  1. DNS server is set to 127.0.0.1 or an unreachable address
  2. Firewall blocking outbound traffic
  3. Network misconfiguration

To fix DNS on each affected node, run:
  pvesh set /nodes/<nodename>/dns -dns1 1.1.1.1 -dns2 8.8.8.8

Then re-run this setup.
#############################################################################
EOF
    return 1
  fi

  success "All nodes have internet connectivity"
  return 0
}

# ensureClusterContext - Load cluster configuration from cluster-info.json
#
# Loads cluster node information and sets PROXMOX_HOST if not already set.
# Required before operations that need cluster topology.
#
# Globals read: CLUSTER_INFO_FILE
# Globals modified: PROXMOX_HOST, CLUSTER_NODES, CLUSTER_NODE_IPS (via loadClusterInfo)
# Arguments: None
# Returns: 0 if cluster info loaded, 1 if cluster-info.json not found
function ensureClusterContext() {
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    loadClusterInfo
    if [ -z "$PROXMOX_HOST" ] && [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
      PROXMOX_HOST="${CLUSTER_NODE_IPS[0]}"
    fi
    return 0
  else
    error "No cluster-info.json found. Run full deployment first."
    return 1
  fi
}

function detectAndSaveCluster() {
  doing "Detecting Proxmox cluster and capturing configuration..."

  CLUSTER_NODES=()
  CLUSTER_NODE_IPS=()

  # Check if this is a cluster by reading /etc/pve/.members
  local MEMBERS_JSON
  MEMBERS_JSON=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "cat /etc/pve/.members 2>/dev/null || echo '{}'")

  local nodes_json="[]"

  if echo "$MEMBERS_JSON" | jq -e '.nodelist' > /dev/null 2>&1; then
    # Multi-node cluster
    IS_CLUSTER=true
    while IFS= read -r line; do
      local name=$(echo "$line" | jq -r '.key')
      local ip=$(echo "$line" | jq -r '.value.ip')
      CLUSTER_NODES+=("$name")
      CLUSTER_NODE_IPS+=("$ip")
    done < <(echo "$MEMBERS_JSON" | jq -c '.nodelist | to_entries[]')
    success "Detected ${#CLUSTER_NODES[@]}-node cluster: ${CLUSTER_NODES[*]}"
  else
    # Single node - get hostname
    IS_CLUSTER=false
    local hostname
    hostname=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "hostname")
    CLUSTER_NODES+=("$hostname")
    CLUSTER_NODE_IPS+=("$PROXMOX_HOST")
    info "Single-node Proxmox (not clustered): $hostname"
  fi

  # Capture DNS configuration for each node
  # Note: At this point, SSH keys may only be installed on primary node, so use password for others
  doing "Capturing DNS configuration per node..."
  local nodes_array="["
  local failed_nodes=()

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Use key-based SSH for primary node, password-based for others
    local ssh_func="sshRunWithPassword"
    [ "$ip" = "$PROXMOX_HOST" ] && ssh_func="sshRun"

    # Get current DNS config
    local dns1="" dns2="" search=""
    local dns_json
    dns_json=$($ssh_func "$REMOTE_USER" "$ip" "pvesh get /nodes/$node/dns --output-format json 2>/dev/null" || echo "{}")

    dns1=$(echo "$dns_json" | jq -r '.dns1 // ""')
    dns2=$(echo "$dns_json" | jq -r '.dns2 // ""')
    search=$(echo "$dns_json" | jq -r '.search // ""')

    # Test connectivity
    local connectivity="unknown"
    if $ssh_func "$REMOTE_USER" "$ip" "curl -s --connect-timeout 5 https://install.pi-hole.net >/dev/null 2>&1 || ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1" 2>/dev/null; then
      connectivity="ok"
      success "  $node ($ip): Connectivity OK, DNS1=$dns1, DNS2=$dns2"
    else
      connectivity="failed"
      failed_nodes+=("$node")
      warn "  $node ($ip): Connectivity FAILED, DNS1=$dns1, DNS2=$dns2"
    fi

    # Build node JSON
    [ $i -gt 0 ] && nodes_array+=","
    nodes_array+=$(jq -n \
      --arg name "$node" \
      --arg ip "$ip" \
      --arg dns1 "$dns1" \
      --arg dns2 "$dns2" \
      --arg search "$search" \
      --arg connectivity "$connectivity" \
      '{name: $name, ip: $ip, dns: {dns1: $dns1, dns2: $dns2, search: $search}, connectivity: $connectivity}')
  done
  nodes_array+="]"

  # Handle failed connectivity
  if [ ${#failed_nodes[@]} -gt 0 ]; then
    echo
    warn "The following nodes have connectivity issues: ${failed_nodes[*]}"
    read -rp "$(question "Would you like to set DNS to 1.1.1.1/8.8.8.8 on failed nodes? [Y/n]: ")" FIX_DNS
    FIX_DNS=${FIX_DNS:-Y}

    if [[ "$FIX_DNS" =~ ^[Yy]$ ]]; then
      for node in "${failed_nodes[@]}"; do
        local idx=-1
        for i in "${!CLUSTER_NODES[@]}"; do
          [ "${CLUSTER_NODES[$i]}" = "$node" ] && idx=$i && break
        done
        [ $idx -ge 0 ] || continue
        local ip="${CLUSTER_NODE_IPS[$idx]}"

        # Use password for secondary nodes since keys aren't distributed yet
        local ssh_func="sshRunWithPassword"
        [ "$ip" = "$PROXMOX_HOST" ] && ssh_func="sshRun"

        doing "  Setting DNS on $node..."
        $ssh_func "$REMOTE_USER" "$ip" "pvesh set /nodes/$node/dns -dns1 1.1.1.1 -dns2 8.8.8.8" 2>/dev/null && \
          success "  $node: DNS updated" || warn "  $node: Failed to update DNS"
      done
    fi
  fi

  # Save initial cluster info (network config added later by configureNetworking)
  jq -n \
    --arg detected_at "$(date -Iseconds)" \
    --argjson is_cluster "$IS_CLUSTER" \
    --argjson nodes "$nodes_array" \
    '{
      detected_at: $detected_at,
      is_cluster: $is_cluster,
      nodes: $nodes,
      primary_node: $nodes[0].name
    }' > "$CLUSTER_INFO_FILE"

  success "Cluster info saved to $CLUSTER_INFO_FILE"
}

function detectClusterNodes() {
  doing "Detecting Proxmox cluster configuration..."

  CLUSTER_NODES=()
  CLUSTER_NODE_IPS=()

  # Check if this is a cluster by reading /etc/pve/.members
  local MEMBERS_JSON
  MEMBERS_JSON=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "cat /etc/pve/.members 2>/dev/null || echo '{}'")

  if echo "$MEMBERS_JSON" | jq -e '.nodelist' > /dev/null 2>&1; then
    # Multi-node cluster
    while IFS= read -r line; do
      local name=$(echo "$line" | jq -r '.key')
      local ip=$(echo "$line" | jq -r '.value.ip')
      CLUSTER_NODES+=("$name")
      CLUSTER_NODE_IPS+=("$ip")
    done < <(echo "$MEMBERS_JSON" | jq -c '.nodelist | to_entries[]')

    success "Detected ${#CLUSTER_NODES[@]}-node cluster: ${CLUSTER_NODES[*]}"
  else
    # Single node - get hostname
    local hostname
    hostname=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "hostname")
    CLUSTER_NODES+=("$hostname")
    CLUSTER_NODE_IPS+=("$PROXMOX_HOST")
    info "Single-node Proxmox (not clustered): $hostname"
  fi

  export CLUSTER_NODES
  export CLUSTER_NODE_IPS
}

# loadClusterInfo - Load cluster configuration from cluster-info.json
#
# Populates global arrays and variables from the saved cluster configuration.
# Called by ensureClusterContext and other functions that need cluster topology.
#
# Globals read: CLUSTER_INFO_FILE
# Globals modified: CLUSTER_NODES, CLUSTER_NODE_IPS, IS_CLUSTER, EXT_CIDR, EXT_GATEWAY,
#                   DNS_START_IP, SVC_START_IP, INT_CIDR, INT_GATEWAY, DNS_POSTFIX,
#                   NETWORK_BRIDGE, TEMPLATE_STORAGE, TEMPLATE_STORAGE_TYPE, USE_SHARED_STORAGE
# Arguments: None
# Returns: 0 on success, 1 if file not found
function loadClusterInfo() {
  if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    warn "Cluster info file not found. Will detect cluster."
    return 1
  fi

  doing "Loading cluster info from $CLUSTER_INFO_FILE..."

  CLUSTER_NODES=()
  CLUSTER_NODE_IPS=()

  while IFS= read -r line; do
    local name=$(echo "$line" | jq -r '.name')
    local ip=$(echo "$line" | jq -r '.ip')
    CLUSTER_NODES+=("$name")
    CLUSTER_NODE_IPS+=("$ip")
  done < <(jq -c '.nodes[]' "$CLUSTER_INFO_FILE")

  IS_CLUSTER=$(jq -r '.is_cluster' "$CLUSTER_INFO_FILE")

  # Load network config if present
  if jq -e '.network' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    EXT_CIDR=$(jq -r '.network.external.cidr // ""' "$CLUSTER_INFO_FILE")
    EXT_GATEWAY=$(jq -r '.network.external.gateway // ""' "$CLUSTER_INFO_FILE")
    DNS_START_IP=$(jq -r '.network.external.dns_start_ip // ""' "$CLUSTER_INFO_FILE")
    SVC_START_IP=$(jq -r '.network.external.services_start_ip // ""' "$CLUSTER_INFO_FILE")
    INT_CIDR=$(jq -r '.network.labnet.cidr // ""' "$CLUSTER_INFO_FILE")
    INT_GATEWAY=$(jq -r '.network.labnet.gateway // ""' "$CLUSTER_INFO_FILE")
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    NETWORK_BRIDGE=$(jq -r '.network.selected_bridge // "vmbr0"' "$CLUSTER_INFO_FILE")
  fi

  # Load storage config if present
  if jq -e '.storage' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    TEMPLATE_STORAGE=$(jq -r '.storage.selected // ""' "$CLUSTER_INFO_FILE")
    TEMPLATE_STORAGE_TYPE=$(jq -r '.storage.type // "lvm"' "$CLUSTER_INFO_FILE")
    USE_SHARED_STORAGE=$(jq -r '.storage.is_shared // false' "$CLUSTER_INFO_FILE")
  fi

  success "Loaded ${#CLUSTER_NODES[@]} nodes from cluster info"
  return 0
}