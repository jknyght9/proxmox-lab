#!/bin/bash

set -euo pipefail
export TERM=xterm

PROXMOX_HOST="${1:-}"
PROXMOX_PASS="${2:-}"

# Global variables
CRYPTO_DIR="crypto"
DNS_POSTFIX=""
KEY_NAME="lab-deploy"
KEY_PATH="$CRYPTO_DIR/$KEY_NAME"
PUBKEY_PATH="$KEY_PATH.pub"
REMOTE_USER="root"
REQUIRED_VMIDS=(903 904 905 906 907 908 909 910 911 912 913 9000 9001 9002 9100 9200)
DNS_VMIDS=(910 911 912 920 921)

# Cluster-related globals (populated by detectAndSaveCluster or loadClusterInfo)
CLUSTER_INFO_FILE="cluster-info.json"
CLUSTER_NODES=()
CLUSTER_NODE_IPS=()
IS_CLUSTER=false
USE_SHARED_STORAGE=false
TEMPLATE_STORAGE="local-lvm"
NETWORK_BRIDGE="vmbr0"

# Network configuration globals (user-provided, stored in cluster-info.json)
EXT_CIDR=""
EXT_GATEWAY=""
DNS_START_IP=""
SVC_START_IP=""
CREATE_SDN=true
INT_CIDR=""
INT_GATEWAY=""

# Deployment phase tracking for rollback
# 0=not started, 1=LXC deployed, 2=Packer built, 3=VMs deployed
DEPLOY_PHASE=0

# Colors for terminal outputs
C_RESET="\033[0m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[0;34m"

# Functions for convenience
function info()         { echo -e "${C_BLUE}[+] $*${C_RESET}"; }
function doing()        { echo -e "${C_BLUE}[>] $*${C_RESET}"; }
function success()      { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
function error()        { echo -e "${C_RED}[X] $*${C_RESET}"; }
function warn()         { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
function question()     { echo -e "  ${C_YELLOW}[?] $*${C_RESET}"; }
function sshRun()       { ssh -i $KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$1@$2" "$3"; }
function pressAnyKey()  { read -n 1 -s -p "$(question "Press any key to continue")"; echo; }

function rollbackDeployment() {
  local phase="${1:-$DEPLOY_PHASE}"

  warn "Deployment failed at phase $phase. Rolling back..."
  echo

  case $phase in
    3)
      # Phase 3 failed: Destroy VMs only, keep LXC infrastructure
      doing "Rolling back Phase 3: Destroying VMs..."
      docker compose run --rm terraform destroy \
        -target=module.docker \
        -target=module.kasm \
        -auto-approve 2>/dev/null || true
      warn "VMs destroyed. LXC infrastructure (DNS, step-ca) preserved."
      ;;
    2)
      # Phase 2 failed: Clean up any partial Packer artifacts
      doing "Rolling back Phase 2: Cleaning Packer artifacts..."
      rm -rf packer/packer-outputs 2>/dev/null || true
      warn "Packer artifacts cleaned."

      read -rp "$(question "Do you want to also destroy LXC containers (DNS, step-ca)? [y/N]: ")" DESTROY_LXC
      if [[ "$DESTROY_LXC" =~ ^[Yy]$ ]]; then
        rollbackDeployment 1
      else
        info "LXC infrastructure preserved. You can retry Packer build."
      fi
      ;;
    1)
      # Phase 1 failed: Destroy all LXC containers
      doing "Rolling back Phase 1: Destroying LXC containers..."
      docker compose run --rm terraform destroy \
        -target=module.dns-main \
        -target=module.dns-labnet \
        -target=module.step-ca \
        -auto-approve 2>/dev/null || true

      # Also clean up any VMIDs that might be orphaned
      for VMID in "${DNS_VMIDS[@]}" 909; do
        ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" \
          "pct stop $VMID 2>/dev/null; pct destroy $VMID 2>/dev/null" 2>/dev/null || true
      done
      warn "LXC containers destroyed."
      ;;
    0)
      info "Nothing to roll back (deployment not started)."
      ;;
  esac

  DEPLOY_PHASE=0
  echo
  error "Rollback complete. Please review the errors above and try again."
}

function header() {
  clear
  cat << "EOF"
   ___                                       __       _
  / _ \_ __ _____  ___ __ ___   _____  __   / /  __ _| |__
 / /_)/ '__/ _ \ \/ / '_ ` _ \ / _ \ \/ /  / /  / _` | '_ \
/ ___/| | | (_) >  <| | | | | | (_) >  <  / /__| (_| | |_) |
\/    |_|  \___/_/\_\_| |_| |_|\___/_/\_\ \____/\__,_|_.__/

EOF
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

function checkClusterConnectivity() {
  doing "Checking internet connectivity on Proxmox nodes..."

  local failed_nodes=()
  local dns_configs=()

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Test internet connectivity (try to reach a reliable endpoint)
    if ! ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_USER@$ip" \
      "curl -s --connect-timeout 5 https://install.pi-hole.net >/dev/null 2>&1 || ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1" 2>/dev/null; then
      failed_nodes+=("$node ($ip)")

      # Get DNS configuration for this node
      local dns_info
      dns_info=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" \
        "echo 'resolv.conf:'; cat /etc/resolv.conf; echo ''; echo 'pvesh DNS:'; pvesh get /nodes/$node/dns --output-format json 2>/dev/null | jq -r 'to_entries[] | \"  \\(.key): \\(.value)\"'" 2>/dev/null)
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
  doing "Capturing DNS configuration per node..."
  local nodes_array="["
  local failed_nodes=()

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Get current DNS config
    local dns1="" dns2="" search=""
    local dns_json
    dns_json=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" \
      "pvesh get /nodes/$node/dns --output-format json 2>/dev/null" || echo "{}")

    dns1=$(echo "$dns_json" | jq -r '.dns1 // ""')
    dns2=$(echo "$dns_json" | jq -r '.dns2 // ""')
    search=$(echo "$dns_json" | jq -r '.search // ""')

    # Test connectivity
    local connectivity="unknown"
    if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_USER@$ip" \
      "curl -s --connect-timeout 5 https://install.pi-hole.net >/dev/null 2>&1 || ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1" 2>/dev/null; then
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

        doing "  Setting DNS on $node..."
        ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" \
          "pvesh set /nodes/$node/dns -dns1 1.1.1.1 -dns2 8.8.8.8" 2>/dev/null && \
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
    TEMPLATE_STORAGE=$(jq -r '.storage.selected // "local-lvm"' "$CLUSTER_INFO_FILE")
  fi

  success "Loaded ${#CLUSTER_NODES[@]} nodes from cluster info"
  return 0
}

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
    sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null
    sshpass -p "$PROXMOX_PASS" scp -o StrictHostKeyChecking=no "$PUBKEY_PATH" "$REMOTE_USER@$ip:/root/.ssh/$KEY_NAME.pub" 2>/dev/null
    sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" \
      "grep -qxF '$(cat "$PUBKEY_PATH")' ~/.ssh/authorized_keys 2>/dev/null \
        || (echo '$(cat "$PUBKEY_PATH")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)" 2>/dev/null
    success "  $node ($ip): Keys installed"
  done

  success "SSH keys distributed to all nodes"
}

function configureNetworking() {
  doing "Configuring network settings..."
  echo

  # Try to get DNS search domain from Proxmox (captured during cluster detection)
  local PROXMOX_DNS_SEARCH=""
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    PROXMOX_DNS_SEARCH=$(jq -r '.nodes[0].dns.search // ""' "$CLUSTER_INFO_FILE")
  fi

  # External network (where Proxmox and services live)
  info "External Network Configuration"
  info "(This is the network where your Proxmox hosts and services will reside)"
  echo

  read -rp "$(question "External network CIDR (e.g., 10.1.50.0/24): ")" EXT_CIDR
  while [ -z "$EXT_CIDR" ]; do
    warn "Network CIDR is required"
    read -rp "$(question "External network CIDR: ")" EXT_CIDR
  done

  # Calculate default gateway from CIDR (assume .1)
  local CIDR_BASE=$(echo "$EXT_CIDR" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.')
  local DEFAULT_GW="${CIDR_BASE}1"

  read -rp "$(question "External gateway [$DEFAULT_GW]: ")" EXT_GATEWAY
  EXT_GATEWAY=${EXT_GATEWAY:-$DEFAULT_GW}

  # Calculate default service IPs from CIDR
  local DEFAULT_DNS_START="${CIDR_BASE}3"
  local DEFAULT_SVC_START="${CIDR_BASE}6"

  echo
  info "Service IP Allocation"
  info "(IP addresses for Pi-hole containers and other services)"
  echo

  read -rp "$(question "Pi-hole containers start IP [$DEFAULT_DNS_START]: ")" DNS_START_IP
  DNS_START_IP=${DNS_START_IP:-$DEFAULT_DNS_START}

  read -rp "$(question "Other services start IP (step-ca, kasm) [$DEFAULT_SVC_START]: ")" SVC_START_IP
  SVC_START_IP=${SVC_START_IP:-$DEFAULT_SVC_START}

  echo
  # Internal/SDN network
  read -rp "$(question "Create internal SDN network (labnet)? [Y/n]: ")" CREATE_SDN_INPUT
  CREATE_SDN_INPUT=${CREATE_SDN_INPUT:-Y}

  if [[ "$CREATE_SDN_INPUT" =~ ^[Yy]$ ]]; then
    CREATE_SDN=true
    echo
    info "Internal SDN Network Configuration"
    info "(This creates an isolated network for internal services)"
    echo

    read -rp "$(question "Internal network CIDR [172.16.0.0/24]: ")" INT_CIDR
    INT_CIDR=${INT_CIDR:-172.16.0.0/24}

    read -rp "$(question "Internal gateway [172.16.0.1]: ")" INT_GATEWAY
    INT_GATEWAY=${INT_GATEWAY:-172.16.0.1}
  else
    CREATE_SDN=false
    INT_CIDR=""
    INT_GATEWAY=""
  fi

  echo
  # DNS domain - use Proxmox search domain as default if available
  info "DNS Domain Configuration"
  if [ -n "$PROXMOX_DNS_SEARCH" ]; then
    info "(Using search domain from Proxmox: $PROXMOX_DNS_SEARCH)"
  fi
  echo

  read -rp "$(question "DNS domain suffix [${PROXMOX_DNS_SEARCH:-lab.local}]: ")" DNS_POSTFIX
  DNS_POSTFIX=${DNS_POSTFIX:-${PROXMOX_DNS_SEARCH:-lab.local}}

  # Display summary
  cat <<EOF

======================================
Network Configuration Summary:
--------------------------------------
External Network:
  CIDR:              $EXT_CIDR
  Gateway:           $EXT_GATEWAY

Service IP Allocation:
  Pi-hole start IP:  $DNS_START_IP
  Services start IP: $SVC_START_IP
EOF

  if $CREATE_SDN; then
    cat <<EOF

Internal SDN Network:
  CIDR:              $INT_CIDR
  Gateway:           $INT_GATEWAY
EOF
  fi

  cat <<EOF

DNS Domain:          $DNS_POSTFIX
======================================

Note: Proxmox nodes will continue using their current DNS
settings until Pi-hole is deployed and configured.

EOF

  read -rp "$(question "Is this correct? [Y/n]: ")" CONFIRM
  CONFIRM=${CONFIRM:-Y}

  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    configureNetworking
    return
  fi

  # Update cluster-info.json with network configuration
  local tmp_file=$(mktemp)
  jq --arg ext_cidr "$EXT_CIDR" \
     --arg ext_gw "$EXT_GATEWAY" \
     --arg dns_start "$DNS_START_IP" \
     --arg svc_start "$SVC_START_IP" \
     --argjson create_sdn "$CREATE_SDN" \
     --arg int_cidr "$INT_CIDR" \
     --arg int_gw "$INT_GATEWAY" \
     --arg dns_postfix "$DNS_POSTFIX" \
     '. + {
       network: {
         external: {
           cidr: $ext_cidr,
           gateway: $ext_gw,
           dns_start_ip: $dns_start,
           services_start_ip: $svc_start
         },
         labnet: {
           enabled: $create_sdn,
           cidr: $int_cidr,
           gateway: $int_gw
         }
       },
       dns_postfix: $dns_postfix
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  success "Network configuration saved to $CLUSTER_INFO_FILE"
}

function ensureLXCTemplates() {
  doing "Ensuring LXC templates are available on all cluster nodes..."

  local TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
  local failed_nodes=()

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Check if template exists on this node
    if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" \
      "test -f /var/lib/vz/template/cache/${TEMPLATE}" 2>/dev/null; then
      info "  $node: Template already exists"
    else
      doing "  $node: Downloading template..."
      if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" \
        "pveam update && pveam download local ${TEMPLATE}" 2>/dev/null; then
        success "  $node: Template downloaded"
      else
        failed_nodes+=("$node ($ip)")
      fi
    fi
  done

  if [ ${#failed_nodes[@]} -gt 0 ]; then
    error "Failed to download template on the following nodes:"
    for node in "${failed_nodes[@]}"; do
      echo "  - $node"
    done
    return 1
  fi

  success "LXC templates available on all nodes"
  return 0
}

function selectSharedStorage() {
  # Check if storage is already configured in cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local EXISTING_STORAGE
    EXISTING_STORAGE=$(jq -r '.storage.selected // ""' "$CLUSTER_INFO_FILE")
    if [ -n "$EXISTING_STORAGE" ] && [ "$EXISTING_STORAGE" != "null" ]; then
      TEMPLATE_STORAGE="$EXISTING_STORAGE"
      USE_SHARED_STORAGE=$(jq -r '.storage.is_shared // false' "$CLUSTER_INFO_FILE")
      export TEMPLATE_STORAGE
      export USE_SHARED_STORAGE
      success "Using configured storage: $TEMPLATE_STORAGE (shared: $USE_SHARED_STORAGE)"
      return 0
    fi
  fi

  doing "Detecting available storage..."

  # Get storage list from first node
  local STORAGE_JSON
  STORAGE_JSON=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "pvesh get /storage --output-format json")

  # Find shared storage (type: rbd, cephfs, nfs, etc.)
  local SHARED_STORES=()
  while IFS= read -r store; do
    [[ -n "$store" ]] && SHARED_STORES+=("$store")
  done < <(echo "$STORAGE_JSON" | jq -r '.[] | select(.shared == 1 and (.content | contains("images"))) | .storage')

  if [ ${#SHARED_STORES[@]} -gt 0 ]; then
    echo
    info "Storage Selection"
    info "Shared storage detected - recommended for clusters"
    echo
    info "Available shared storage:"
    for i in "${!SHARED_STORES[@]}"; do
      echo "    $((i + 1)). ${SHARED_STORES[$i]} (shared)"
    done
    echo "    $((${#SHARED_STORES[@]} + 1)). local-lvm (per-node)"
    echo

    local DEFAULT_STORE="${SHARED_STORES[0]}"
    read -rp "$(question "Select storage [$DEFAULT_STORE]: ")" STORAGE_CHOICE
    STORAGE_CHOICE=${STORAGE_CHOICE:-$DEFAULT_STORE}

    # Check if user entered a number or a name
    if [[ "$STORAGE_CHOICE" =~ ^[0-9]+$ ]]; then
      if [ "$STORAGE_CHOICE" -le "${#SHARED_STORES[@]}" ] && [ "$STORAGE_CHOICE" -ge 1 ]; then
        TEMPLATE_STORAGE="${SHARED_STORES[$((STORAGE_CHOICE - 1))]}"
        USE_SHARED_STORAGE=true
      else
        TEMPLATE_STORAGE="local-lvm"
        USE_SHARED_STORAGE=false
      fi
    elif [ "$STORAGE_CHOICE" = "local-lvm" ]; then
      TEMPLATE_STORAGE="local-lvm"
      USE_SHARED_STORAGE=false
    else
      # Assume they typed the storage name
      TEMPLATE_STORAGE="$STORAGE_CHOICE"
      USE_SHARED_STORAGE=true
    fi
  else
    warn "No shared storage found. Using local-lvm (templates must exist on each node)"
    TEMPLATE_STORAGE="local-lvm"
    USE_SHARED_STORAGE=false
  fi

  export TEMPLATE_STORAGE
  export USE_SHARED_STORAGE
  success "Using storage: $TEMPLATE_STORAGE (shared: $USE_SHARED_STORAGE)"
}

function selectNetworkBridge() {
  # Check if bridge is already configured in cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local EXISTING_BRIDGE
    EXISTING_BRIDGE=$(jq -r '.network.selected_bridge // ""' "$CLUSTER_INFO_FILE")
    if [ -n "$EXISTING_BRIDGE" ] && [ "$EXISTING_BRIDGE" != "null" ]; then
      NETWORK_BRIDGE="$EXISTING_BRIDGE"
      export NETWORK_BRIDGE
      success "Using configured network bridge: $NETWORK_BRIDGE"
      return 0
    fi
  fi

  doing "Detecting network bridges available on all cluster nodes..."

  # Get bridges from each node and find common ones
  local ALL_BRIDGES=()
  local FIRST_NODE=true

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Get bridges on this node (excluding vmbr for internal use)
    local NODE_BRIDGES=()
    while IFS= read -r bridge; do
      [[ -n "$bridge" ]] && NODE_BRIDGES+=("$bridge")
    done < <(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" \
      "pvesh get /nodes/$node/network --output-format json 2>/dev/null" | \
      jq -r '.[] | select(.type == "bridge") | .iface' 2>/dev/null)

    if $FIRST_NODE; then
      ALL_BRIDGES=("${NODE_BRIDGES[@]}")
      FIRST_NODE=false
    else
      # Find intersection with previous nodes
      local COMMON_BRIDGES=()
      for bridge in "${ALL_BRIDGES[@]}"; do
        for nb in "${NODE_BRIDGES[@]}"; do
          if [[ "$bridge" == "$nb" ]]; then
            COMMON_BRIDGES+=("$bridge")
            break
          fi
        done
      done
      ALL_BRIDGES=("${COMMON_BRIDGES[@]}")
    fi
  done

  if [ ${#ALL_BRIDGES[@]} -eq 0 ]; then
    warn "No common network bridges found across all nodes. Using vmbr0."
    NETWORK_BRIDGE="vmbr0"
  elif [ ${#ALL_BRIDGES[@]} -eq 1 ]; then
    NETWORK_BRIDGE="${ALL_BRIDGES[0]}"
    info "Only one common bridge found: $NETWORK_BRIDGE"
  else
    echo
    info "Network Bridge Selection"
    info "Available bridges (present on all nodes):"
    echo
    for i in "${!ALL_BRIDGES[@]}"; do
      echo "    $((i + 1)). ${ALL_BRIDGES[$i]}"
    done
    echo

    local DEFAULT_BRIDGE="${ALL_BRIDGES[0]}"
    read -rp "$(question "Select network bridge [$DEFAULT_BRIDGE]: ")" BRIDGE_CHOICE
    BRIDGE_CHOICE=${BRIDGE_CHOICE:-$DEFAULT_BRIDGE}

    # Check if user entered a number or a name
    if [[ "$BRIDGE_CHOICE" =~ ^[0-9]+$ ]]; then
      if [ "$BRIDGE_CHOICE" -le "${#ALL_BRIDGES[@]}" ] && [ "$BRIDGE_CHOICE" -ge 1 ]; then
        NETWORK_BRIDGE="${ALL_BRIDGES[$((BRIDGE_CHOICE - 1))]}"
      else
        NETWORK_BRIDGE="$DEFAULT_BRIDGE"
      fi
    else
      # Assume they typed the bridge name
      NETWORK_BRIDGE="$BRIDGE_CHOICE"
    fi
  fi

  export NETWORK_BRIDGE
  success "Using network bridge: $NETWORK_BRIDGE"
}

function cleanupDNSVMIDs() {
  doing "Checking for existing DNS VMIDs that need cleanup..."
  local cleaned=0

  for VMID in "${DNS_VMIDS[@]}"; do
    # Check if LXC container exists
    if ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "pct status $VMID" &>/dev/null; then
      warn "VMID $VMID exists, destroying for clean deployment"
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "pct stop $VMID 2>/dev/null || true; pct destroy $VMID 2>/dev/null || true"
      ((cleaned++))
    fi
  done

  if [ $cleaned -gt 0 ]; then
    success "Cleaned up $cleaned existing DNS container(s)"
  else
    info "No existing DNS containers found"
  fi
}

function checkRequirements() {
  # Check if sshpass is installed
  if ! command -v sshpass >/dev/null 2>&1; then
    error "'sshpass' is not installed. Please install it and try again."
    echo "  Debian/Ubuntu: sudo apt install sshpass"
    echo "  macOS (Homebrew): brew install hudochenkov/sshpass/sshpass"
    echo "  Fedora: sudo dnf install sshpass"
    exit 1
  fi
  
  # Check if jq is installed
  if ! command -v jq >/dev/null 2>&1; then
    error "'jq' is not installed. Please install it and try again."
    echo "  Debian/Ubuntu: sudo apt install jq"
    echo "  macOS (Homebrew): brew install jq"
    echo "  Fedora: sudo dnf install jq"
    exit 1
  fi

  # Check if Docker Engine is installed
  if ! command -v docker >/dev/null 2>&1; then
    error "'docker' is not installed. Please install Docker Engine."
    echo "  https://docs.docker.com/engine/install/"
    exit 1
  fi

  # Check if Docker Engine is running
  if ! docker info >/dev/null 2>&1; then
    error "Docker Engine is installed but not running or not accessible."
    echo "  Make sure the docker service is started:"
    echo "    sudo systemctl start docker"
    echo "  Or check permissions (your user may need to be in the 'docker' group)."
    exit 1
  fi

  success "All requirements met: sshpass, jq, and Docker are available and running."
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
  if ! sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_USER@$PROXMOX_HOST" "echo SSH connection successful" >/dev/null 2>&1; then
    error "SSH connection failed. Check password or network."
    exit 1
  fi
  success "Successfully connected to $PROXMOX_HOST.\n"
}

function installSSHKeys() {
  doing "Installing SSH public key..."
  sshpass -p "$PROXMOX_PASS" ssh "$REMOTE_USER@$PROXMOX_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  sshpass -p "$PROXMOX_PASS" scp "$PUBKEY_PATH" "$REMOTE_USER@$PROXMOX_HOST":/root/.ssh/$KEY_NAME.pub
  sshpass -p "$PROXMOX_PASS" ssh "$REMOTE_USER@$PROXMOX_HOST" \
  "grep -qxF '$(cat "$PUBKEY_PATH")' ~/.ssh/authorized_keys \
    || (echo '$(cat "$PUBKEY_PATH")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)"
  success "Public key installed successfully on $PROXMOX_HOST.\n"
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
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$ip" \
        'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"' \
        && success "Completed post-installation on $node" \
        || warn "Post-installation may have failed on $node"
    done

    success "Post-installation complete on all nodes"
  else
    warn "Skipped running the post-install script"
  fi
}

function proxmoxLabInstall() {
  doing "Running Proxmox VE Lab Install Script..."
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no ./proxmox/setup.sh "$REMOTE_USER@$PROXMOX_HOST":/root/
  #sshRun $REMOTE_USER $PROXMOX_HOST 'bash -c "chmod +x /root/setup.sh && /root/setup.sh"'
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" 'bash -c "chmod +x /root/setup.sh && /root/setup.sh"'
  success "Completed the lab installation script on $PROXMOX_HOST\n"
}

function generateCertificates() {
  doing "Setting up step-ca for certificate generation"
  STEPCA_DIR="terraform/lxc-step-ca/step-ca"
  if [ ! -d "$STEPCA_DIR" ]; then
    mkdir -p terraform/lxc-step-ca/step-ca
  fi
  docker compose run --rm -it step-ca
  success "Certificate generation complete.\n"
}

function deployServices() {
  cat <<EOF

############################################################################
Services Deployment

Deploying critical services: Pi-hole DNS with Unbound (DNS-over-TLS),
Certificate Authority (Step-CA), Kasm, and Docker Swarm cluster.
#############################################################################

EOF

  # Load configuration from cluster-info.json if not already loaded
  if [ -z "$DNS_POSTFIX" ] && [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
  fi

  # If still no DNS_POSTFIX, prompt for it
  if [ -z "$DNS_POSTFIX" ]; then
    read -rp "$(question "Enter DNS domain suffix (e.g., lab.local): ")" DNS_POSTFIX
    while [ -z "$DNS_POSTFIX" ]; do
      warn "DNS domain suffix is required"
      read -rp "$(question "DNS domain suffix: ")" DNS_POSTFIX
    done
  fi

  # Prompt for Pi-hole password (required, no default)
  while true; do
    read -rsp "$(question "Enter Pi-hole admin password: ")" PIHOLE_PASSWORD
    echo ""
    if [ -z "$PIHOLE_PASSWORD" ]; then
      warn "Password cannot be empty"
      continue
    fi
    read -rsp "$(question "Confirm Pi-hole admin password: ")" PIHOLE_PASSWORD_CONFIRM
    echo ""
    if [ "$PIHOLE_PASSWORD" != "$PIHOLE_PASSWORD_CONFIRM" ]; then
      warn "Passwords do not match"
      continue
    fi
    break
  done

  # Display configuration summary
  cat <<EOF

======================================
Deployment Configuration:
--------------------------------------
DNS suffix:               $DNS_POSTFIX
Pi-hole admin pass:       $PIHOLE_PASSWORD
======================================

EOF

  read -rp "$(question "Proceed with deployment? [Y/n]: ")" CONFIRM
  CONFIRM=${CONFIRM:-Y}
  [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && warn "Deployment cancelled" && return 1

  # Update the step-ca installation script with DNS postfix
  if sed --version >/dev/null 2>&1; then
      sed -i "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
  else
      sed -i '' "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
  fi
  success "Step-CA installation script updated"

  # Generate certificates
  generateCertificates

  # Load cluster info if not already loaded
  if [ ${#CLUSTER_NODES[@]} -eq 0 ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      loadClusterInfo
    else
      detectClusterNodes
    fi
  fi

  # Verify all nodes can reach the internet before proceeding
  if ! checkClusterConnectivity; then
    error "Cannot proceed without internet connectivity on all nodes."
    return 1
  fi

  # Ensure LXC templates are available on all nodes
  if ! ensureLXCTemplates; then
    error "Cannot proceed without LXC templates on all nodes."
    return 1
  fi

  # Checking VMIDs
  doing "Checking if required Proxmox VMIDs currently exist..."
  manageVMIDs "${REQUIRED_VMIDS[@]}"
  success "VMID check complete\n"

  # Clean up any existing DNS containers before terraform
  cleanupDNSVMIDs

  # ============================================
  # PHASE 1: Deploy LXC Containers (DNS, step-ca)
  # ============================================
  cat <<EOF

#############################################################################
LXC Container Deployment

Deploying critical infrastructure: DNS servers and Certificate Authority.
These must be operational before building VM templates.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying LXC containers (DNS, step-ca)..."
  docker compose build terraform >/dev/null 2>&1
  docker compose run --rm -it terraform init

  if ! docker compose run --rm -it terraform apply \
    -target=module.dns-main \
    -target=module.dns-labnet \
    -target=module.step-ca; then
    error "Phase 1 failed: LXC container deployment"
    DEPLOY_PHASE=1
    read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
    DO_ROLLBACK=${DO_ROLLBACK:-Y}
    if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
      rollbackDeployment 1
    fi
    return 1
  fi

  DEPLOY_PHASE=1
  success "Phase 1 complete: LXC containers deployed"

  # Refresh terraform state to update outputs after targeted apply
  doing "Refreshing Terraform state to update outputs..."
  docker compose run --rm -T terraform refresh -target=module.dns-main -target=module.dns-labnet -target=module.step-ca >/dev/null 2>&1 || true

  # Generate hosts.json from terraform output (may be partial during Phase 1)
  doing "Generating hosts.json from Terraform outputs..."
  if docker compose run --rm -T terraform output -json host-records > hosts.json 2>&1; then
    # Check if the output is valid JSON (not an error message)
    if jq -e '.external' hosts.json >/dev/null 2>&1; then
      success "hosts.json generated successfully"
    else
      warn "hosts.json contains invalid data, recreating from individual outputs..."
      generateHostsJsonFromModules
    fi
  else
    warn "Could not generate hosts.json from terraform output, using individual module outputs..."
    generateHostsJsonFromModules
  fi

  updateDNSRecords
  updateRootCertificates

  # ============================================
  # PHASE 2: Build Packer Templates
  # ============================================
  cat <<EOF

#############################################################################
Template Creation

Building VM templates with Packer. DNS and CA are now available.
Please make sure that you update your packer.auto.pkvars.hcl before starting.
#############################################################################
EOF
  pressAnyKey

  doing "Building Packer templates..."
  docker compose build packer >/dev/null 2>&1
  docker compose run --rm -it packer init .
  if ! docker compose run --rm -it packer build .; then
    error "Phase 2 failed: Packer build was not successful"
    DEPLOY_PHASE=2
    read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
    DO_ROLLBACK=${DO_ROLLBACK:-Y}
    if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
      rollbackDeployment 2
    fi
    return 1
  fi

  DEPLOY_PHASE=2
  success "Phase 2 complete: Packer templates built"

  # ============================================
  # PHASE 3: Deploy VMs (docker-swarm, kasm)
  # ============================================
  cat <<EOF

#############################################################################
VM Deployment

Deploying Docker Swarm and Kasm VMs from templates.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying VMs..."
  if ! docker compose run --rm -it terraform apply; then
    error "Phase 3 failed: VM deployment"
    DEPLOY_PHASE=3
    read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
    DO_ROLLBACK=${DO_ROLLBACK:-Y}
    if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
      rollbackDeployment 3
    fi
    return 1
  fi

  docker compose run --rm -it terraform refresh
  docker compose run --rm -it terraform output -json host-records > hosts.json

  DEPLOY_PHASE=3
  success "Phase 3 complete: VMs deployed"
  success "Deployment complete!"
}

# Generic LXC template creation function
# Parameters: VMID, template name, install script path, storage, bridge, cores, memory
function createLXCTemplate() {
  local TEMPLATE_VMID="$1"
  local TEMPLATE_NAME="$2"
  local INSTALL_SCRIPT="$3"
  local STORAGE="${4:-local-lvm}"
  local BRIDGE="${5:-vmbr0}"
  local CORES="${6:-2}"
  local MEMORY="${7:-2048}"

  doing "Creating LXC template: ${TEMPLATE_NAME} (VMID: ${TEMPLATE_VMID})"
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no "$INSTALL_SCRIPT" "$REMOTE_USER@$PROXMOX_HOST":/root/install.sh

  doing "Creating LXC container ${TEMPLATE_VMID} (${TEMPLATE_NAME})..."
  local OSTEMPLATE=$(sshRun $REMOTE_USER $PROXMOX_HOST "pveam list local | awk '/vztmpl/ {print \$1; exit}'")
  echo $OSTEMPLATE
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" "\
    pct stop ${TEMPLATE_VMID} || true > /dev/null 2>&1 && pct destroy ${TEMPLATE_VMID} || true > /dev/null 2>&1
    pct create ${TEMPLATE_VMID} ${OSTEMPLATE} \
      --storage ${STORAGE} \
      --hostname ${TEMPLATE_NAME} \
      --cores ${CORES} \
      --memory ${MEMORY} \
      --net0 name=eth0,bridge=${BRIDGE},ip=dhcp \
      --start
    pct set ${TEMPLATE_VMID} -features nesting=1,keyctl=1
    pct exec ${TEMPLATE_VMID} -- bash -c '
      mkdir -p /root/.ssh &&
      chmod 700 /root/.ssh &&
      touch /root/.ssh/authorized_keys &&
      chmod 600 /root/.ssh/authorized_keys'
    pct push ${TEMPLATE_VMID} /root/.ssh/lab-deploy.pub /root/lab-deploy.pub
    pct exec ${TEMPLATE_VMID} -- bash -c 'cat /root/lab-deploy.pub >> /root/.ssh/authorized_keys && rm /root/lab-deploy.pub'
    pct reboot ${TEMPLATE_VMID}"

  doing "Running installation script..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "\
    pct push ${TEMPLATE_VMID} /root/install.sh /root/install.sh && \
    pct exec ${TEMPLATE_VMID} -- bash -c 'bash /root/install.sh'" || true

  doing "Cleaning container for template..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" "pct exec ${TEMPLATE_VMID} -- bash -c 'apt-get clean && \
    rm -rf /tmp/* /var/tmp/* /var/log/* /root/.bash_history && \
    truncate -s 0 /etc/machine-id && \
    rm -f /etc/ssh/ssh_host_* && \
    ssh-keygen -A && \
    systemctl enable ssh'"

  doing "Stopping container and converting to template..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" "pct stop ${TEMPLATE_VMID} && pct template ${TEMPLATE_VMID} && pct set ${TEMPLATE_VMID} -ostype debian"
  success "LXC template '${TEMPLATE_NAME}' created successfully"
}

function setupDockerSwarm() {
  BRICK="/gluster/volume1"
  VOL="swarm-data"
  MOUNTPOINT="/srv/gluster/${VOL}"
  SSH_USERNAME=$(jq -r '.[] | select(.build | contains("docker")) | .ssh_username' packer/packer-outputs/template-credentials.json)
  
  doing "Setting up docker swarm"
  NODE_IPS=()
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && NODE_IPS+=("$ip")
  done < <(
    jq -r '.external[] | select(.hostname | contains("docker")) | .ip' hosts.json \
    | sed 's:/.*$::'
  )
  
  if ((${#NODE_IPS[@]} < 1)); then
    echo "No hosts found to configure."
    exit 1
  fi

  MGR="${NODE_IPS[0]}"
  ND1="${NODE_IPS[1]}"
  ND2="${NODE_IPS[2]}"

  # doing "Ensuring GlusterFS is running on nodes"
  # for ip in "${NODE_IPS[@]}"; do
  #   sshRun "$ip" "systemctl enable --now glusterd || systemctl enable --now glusterfsd || true"
  #   sshRun "$ip" "mkdir -p '$BRICK'"
  # done 

  # Probe peers
  for peer in "${NODE_IPS[@]}"; do
    if ! sshRun "$REMOTE_USER" "$MGR" "gluster pool list | awk '{print \$2}' | grep -qx '$peer'"; then 
      doing "Probing peer $peer"
      sshRun "$REMOTE_USER" "$MGR" "gluster peer probe $peer"
    else 
      info "$peer is already in pool"
    fi
  done

  sleep 2

  # # Wait for connections
  # for peer in "${NODE_IPS[@]}"; do
  #   until sshRun "$REMOTE_USER" "$MGR" "gluster peer status | grep -A1 -w '$peer' | grep -q Connected"; do
  #     sleep 2
  #   done
  # done

  # sleep 2

  # Create and start volume
  BRICKS="$MGR:$BRICK $ND1:$BRICK $ND2:$BRICK"
  if ! sshRun "$REMOTE_USER" "$MGR" "gluster volume info $VOL >/dev/null 2>&1"; then
    doing "Creating volume $VOL"
    sshRun "$REMOTE_USER" "$MGR" "gluster volume create $VOL replica 3 $BRICKS force"
  else
    info "Volume $VOL exists"
  fi

  if ! sshRun "$REMOTE_USER" "$MGR" "gluster volume status $VOL >/dev/null 2>&1"; then
    doing "Starting volume $VOL"
    sshRun "$REMOTE_USER" "$MGR" "gluster volume start $VOL"
  fi

  sleep 2

  # Set recommended options
  for opt in \
    "cluster.quorum-type auto" \
    "cluster.self-heal-daemon on" \
    "cluster.data-self-heal on" \
    "cluster.metadata-self-heal on" \
    "cluster.entry-self-heal on" \
    "performance.client-io-threads on" \
    "network.ping-timeout 10"
  do
    sshRun "$REMOTE_USER" "$MGR" "gluster volume set $VOL $opt || true"
  done

  sleep 2

  # Mount with fstab
  PREF="$MGR"
  BACKUPS=$(printf ",backupvolfile-server=%s" "$ND1" "$ND2")
  for ip in "${NODE_IPS[@]}"; do
    doing "Mounting on $ip"
    sshRun "$REMOTE_USER" "$ip" "mkdir -p '$MOUNTPOINT'"
    sshRun "$REMOTE_USER" "$ip" "sed -i \"/:${VOL}[[:space:]]/d\" /etc/fstab"
    sshRun "$REMOTE_USER" "$ip" "echo '${PREF}:/${VOL} ${MOUNTPOINT} glusterfs defaults,_netdev${BACKUPS} 0 0' | tee -a /etc/fstab >/dev/null"
    sshRun "$REMOTE_USER" "$ip" "mount -a || mount.glusterfs ${PREF}:/${VOL} ${MOUNTPOINT}"
  done

  sleep 2

  # Verify
  sshRun "$REMOTE_USER" "$MGR" "gluster volume info $VOL"
  sshRun "$REMOTE_USER" "$MGR" "gluster volume status $VOL"
  sshRun "$REMOTE_USER" "$MGR" "gluster volume heal $VOL info || true"

  success "GlusterFS '$VOL' up on: ${NODE_IPS[*]}"
  info "Mounted at ${MOUNTPOINT} on each node."

  NODES=("${NODE_IPS[@]:1}")

  info "Manager Primary: $MGR"
  info "Managers: ${NODES[*]:-<none>}"

  doing "Initializing docker swarm primary manager $MGR"
  sshRun "$REMOTE_USER" "$MGR" "docker swarm init --advertise-addr $MGR || true"
  MANAGER_TOKEN=$(sshRun "$REMOTE_USER" "$MGR" "docker swarm join-token -q manager")
  WORKER_TOKEN=$(sshRun "$REMOTE_USER" "$MGR" "docker swarm join-token -q worker")

  sleep 2
  
  doing "Adding additional nodes to swarm"
  for ip in "${NODES[@]}"; do
    info "Manager join: $ip"
    sshRun "$REMOTE_USER" "$ip" "sudo docker swarm join --token $MANAGER_TOKEN $MGR:2377 || true"
  done

  sleep 2

  doing "Adding Portainer to swarm"
  PORTAINER_DIR=${BRICK}/portainer
  PORTAINER_FILE=${PORTAINER_DIR}/portainer-agent-stack.yml
  PORTAINER_SERVICE_DIR=${BRICK}/services/portainer

  sshRun "$REMOTE_USER" "$MGR" "mkdir -p ${PORTAINER_DIR} ${PORTAINER_SERVICE_DIR} \
    && curl -L https://downloads.portainer.io/ce-lts/portainer-agent-stack.yml -o ${PORTAINER_FILE} \
    && sed -i 's|portainer_data:/data|/gluster/volume1/services/portainer:/data|' ${PORTAINER_FILE} \
    && docker stack deploy -c ${PORTAINER_FILE} portainer \
    && docker node ls \
    && docker service ls \
    && gluster pool list"
}

function manageVMIDs() {
  local VMIDS=("$@")

  for VMID in "${VMIDS[@]}"; do
    # Check if QEMU VM exists
    if ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "qm config $VMID" &>/dev/null; then
      warn "VMID $VMID is a QEMU VM"
      read -rp "$(question "Do you want to destroy VMID $VMID (y/N)? ")" REPLY
      if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        ssh -i "$KEY_PATH" "$REMOTE_USER@$PROXMOX_HOST" "qm stop $VMID || true && qm destroy $VMID || true"
        success "QEMU VM $VMID destroyed."
      fi

    # Check if LXC container exists
    elif ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "pct config $VMID" &>/dev/null; then
      warn "VMID $VMID is an LXC container"
      read -rp "$(question "Do you want to destroy VMID $VMID (y/N)? ")" REPLY
      if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        ssh -i "$KEY_PATH" "$REMOTE_USER@$PROXMOX_HOST" "pct stop $VMID || true && pct destroy $VMID || true"
        success "LXC container $VMID destroyed."
      fi

    else
      info "VMID $VMID does not exist"
    fi
  done
}

function generateHostsJsonFromModules() {
  # Generate hosts.json by querying individual module outputs
  # This is used when the combined host-records output fails (e.g., during targeted apply)
  doing "Generating hosts.json from individual module outputs..."

  local EXTERNAL_HOSTS="[]"
  local INTERNAL_HOSTS="[]"

  # Query terraform state directly using terraform show
  local TF_STATE
  TF_STATE=$(docker compose run --rm -T terraform show -json 2>/dev/null) || true

  if [ -n "$TF_STATE" ] && [ "$TF_STATE" != "null" ]; then
    # Extract dns-main hosts from state (proxmox_lxc resource)
    local DNS_HOSTS
    DNS_HOSTS=$(echo "$TF_STATE" | jq -c '
      [.values.root_module.child_modules[]? |
       select(.address | startswith("module.dns-main")) |
       .resources[]? |
       select(.type == "proxmox_lxc") |
       {hostname: .values.hostname, ip: .values.network[0].ip}
      ] // []' 2>/dev/null) || DNS_HOSTS="[]"

    # Extract step-ca hosts from state
    local STEP_CA_HOSTS
    STEP_CA_HOSTS=$(echo "$TF_STATE" | jq -c '
      [.values.root_module.child_modules[]? |
       select(.address | startswith("module.step-ca")) |
       .resources[]? |
       select(.type == "proxmox_lxc") |
       {hostname: .values.hostname, ip: .values.network[0].ip}
      ] // []' 2>/dev/null) || STEP_CA_HOSTS="[]"

    # Extract dns-labnet hosts from state (internal)
    local LABNET_HOSTS
    LABNET_HOSTS=$(echo "$TF_STATE" | jq -c '
      [.values.root_module.child_modules[]? |
       select(.address | startswith("module.dns-labnet")) |
       .resources[]? |
       select(.type == "proxmox_lxc") |
       {hostname: .values.hostname, ip: .values.network[0].ip}
      ] // []' 2>/dev/null) || LABNET_HOSTS="[]"

    # Combine external hosts
    EXTERNAL_HOSTS=$(jq -c -n --argjson dns "$DNS_HOSTS" --argjson ca "$STEP_CA_HOSTS" '$dns + $ca')
    INTERNAL_HOSTS="$LABNET_HOSTS"
  fi

  # Create the hosts.json structure
  jq -n --argjson ext "$EXTERNAL_HOSTS" --argjson int "$INTERNAL_HOSTS" \
    '{external: $ext, internal: $int}' > hosts.json

  if jq -e '.external | length > 0' hosts.json >/dev/null 2>&1; then
    success "Generated hosts.json from module state"
    return 0
  else
    warn "No hosts found in terraform state"
    return 1
  fi
}

function generateHostsJson() {
  doing "Generating hosts.json from Terraform output..."

  if [ ! -d "terraform" ]; then
    warn "terraform directory not found"
    return 1
  fi

  # Try to get hosts from Terraform output
  local TF_OUTPUT
  TF_OUTPUT=$(docker compose run --rm -T terraform output -json host-records 2>/dev/null) || true

  if [ -n "$TF_OUTPUT" ] && [ "$TF_OUTPUT" != "null" ] && jq -e '.external' <<<"$TF_OUTPUT" >/dev/null 2>&1; then
    echo "$TF_OUTPUT" > hosts.json
    success "Generated hosts.json from Terraform output"
    return 0
  fi

  # Fallback to individual module outputs
  generateHostsJsonFromModules
}

function updateDNSRecords() {
  # Load configuration from cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    PROXMOX_HOST=$(jq -r '.nodes[0].ip // ""' "$CLUSTER_INFO_FILE")

    # Load cluster nodes if not already loaded
    if [ ${#CLUSTER_NODES[@]} -eq 0 ]; then
      loadClusterInfo
    fi
  fi

  if [ -z "${DNS_POSTFIX}" ]; then
    read -rp "$(question "Enter your DNS suffix: ")" DNS_POSTFIX
  fi

  if [ -z "${PROXMOX_HOST}" ]; then
    read -rp "$(question "Enter Proxmox host IP: ")" PROXMOX_HOST
  fi

  # Try to generate/update hosts.json from Terraform
  if [ ! -s hosts.json ]; then
    generateHostsJson || true
  fi

  doing "Reading Proxmox node info from cluster-info.json..."
  local NODE_RECORDS_JSON="[]"
  local NODE_RECORDS_ALIAS_JSON="[]"

  if [ -f "$CLUSTER_INFO_FILE" ]; then
    # Generate Proxmox node records from cluster-info.json
    NODE_RECORDS_JSON="$(jq -c --arg suffix "$DNS_POSTFIX" \
      '[.nodes[] | "\(.ip) \(.name) \(.name).\($suffix)"]' "$CLUSTER_INFO_FILE")"
    # Create proxmox alias pointing to first node
    NODE_RECORDS_ALIAS_JSON="$(jq -c --arg suffix "$DNS_POSTFIX" \
      '[.nodes[0] | "\(.ip) proxmox proxmox.\($suffix)"]' "$CLUSTER_INFO_FILE")"

    echo "  Proxmox nodes:"
    jq -r '.nodes[] | "    - \(.name).\($suffix) -> \(.ip)"' --arg suffix "$DNS_POSTFIX" "$CLUSTER_INFO_FILE"
  else
    warn "cluster-info.json not found, skipping Proxmox node records"
  fi

  doing "Generating service DNS records from hosts.json..."
  local EXT_RECORDS_JSON="[]"
  local DNS_IP=""

  if [ -s hosts.json ]; then
    EXT_RECORDS_JSON="$(jq -c --arg suffix "$DNS_POSTFIX" \
      '(.external // []) | map("\((.ip | split("/")[0])) \(.hostname) \(.hostname)." + $suffix)' hosts.json)"
    DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json | cut -d'/' -f1)

    echo "  Services:"
    jq -r --arg suffix "$DNS_POSTFIX" \
      '(.external // [])[] | "    - \(.hostname).\($suffix) -> \(.ip | split("/")[0])"' hosts.json
  else
    warn "hosts.json not found - only Proxmox node records will be added"
    warn "Run Terraform apply first, or create hosts.json manually"
  fi

  if [ -z "$DNS_IP" ]; then
    read -rp "$(question "Enter primary DNS server IP (dns-01): ")" DNS_IP
  fi

  # Add "dns" alias pointing to dns-01
  local DNS_ALIAS_JSON
  DNS_ALIAS_JSON="$(jq -c -n --arg ip "$DNS_IP" --arg suffix "$DNS_POSTFIX" '["\($ip) dns dns.\($suffix)"]')"

  local ALL_DNS_RECORDS_JSON
  ALL_DNS_RECORDS_JSON="$(jq -c -n \
    --argjson a "$NODE_RECORDS_JSON" \
    --argjson b "$EXT_RECORDS_JSON" \
    --argjson c "$NODE_RECORDS_ALIAS_JSON" \
    --argjson d "$DNS_ALIAS_JSON" \
    '$a + $b + $c + $d | unique')"

  local RECORD_COUNT
  RECORD_COUNT=$(jq -r 'length' <<<"$ALL_DNS_RECORDS_JSON")

  echo
  info "Summary: $RECORD_COUNT A-records to add"

  doing "Updating Pi-hole @ $DNS_IP..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$DNS_IP" "
    pihole-FTL --config dns.hosts '$ALL_DNS_RECORDS_JSON' &&
    pihole-FTL --config dns.cnameRecords '[\"ca.$DNS_POSTFIX,step-ca.$DNS_POSTFIX\"]'
  " && success "Pi-hole DNS records updated" || error "Failed to update Pi-hole"

  # Trigger Nebula-Sync to propagate changes
  doing "Triggering Nebula-Sync to propagate to replicas..."
  if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes "$REMOTE_USER@$DNS_IP" \
    "systemctl start nebula-sync.service && systemctl status nebula-sync.service --no-pager | head -5"; then
    success "Sync triggered"
  else
    warn "Nebula-Sync sync failed or not configured - records may need manual sync"
  fi

  read -rp "$(question "Update Proxmox nodes to use this DNS server? [Y/n]: ")" UPDATE_PROXMOX
  UPDATE_PROXMOX=${UPDATE_PROXMOX:-Y}

  if [[ "$UPDATE_PROXMOX" =~ ^[Yy]$ ]]; then
    doing "Updating Proxmox nodes' DNS settings..."
    for i in "${!CLUSTER_NODES[@]}"; do
      local node="${CLUSTER_NODES[$i]}"
      local ip="${CLUSTER_NODE_IPS[$i]}"
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" \
        "sed -i '/^nameserver/d' /etc/resolv.conf && echo 'nameserver $DNS_IP' >> /etc/resolv.conf && echo 'nameserver 1.1.1.1' >> /etc/resolv.conf"
      echo "  - $node: DNS set to $DNS_IP"
    done
    success "Proxmox DNS settings updated"
  fi
}

function updateRootCertificates() {
  if [ -z "${DNS_POSTFIX}" ]; then
    read -rp "Enter your DNS suffix: " DNS_POSTFIX
  fi

  if [ -s hosts.json ]; then
    CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json | cut -d'/' -f1)
  fi
  if [[ -z "$CA_IP" ]]; then
    read -rp "Enter CA IP address: " CA_IP
  fi

  local CA_URL="https://$CA_IP/roots.pem"
  local ACME_DIR="https://ca.${DNS_POSTFIX}/acme/acme/directory"

  doing "Reading node list from ${PROXMOX_HOST}:/etc/pve/.members"
  local MEMBERS_JSON
  MEMBERS_JSON="$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" 'cat /etc/pve/.members')"
  local NODE_IPS=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && NODE_IPS+=("$name")
  done < <(jq -r '.nodelist | to_entries[] | .value.ip' <<<"$MEMBERS_JSON")

  if ((${#NODE_IPS[@]}==0)); then
    error "No nodes found in /etc/pve/.members"; return 1
  fi

  doing "Downloading Step CA root bundle: $CA_URL"
  curl -fsS -k -o proxmox-lab-root-ca.crt "$CA_URL" || { echo "Failed to fetch $CA_URL"; return 1; }

  doing "Installing root CA on all nodes and updating trust"
  for name in "${NODE_IPS[@]}"; do
    echo "  - $name"
    scp -i "$KEY_PATH" -o StrictHostKeyChecking=no proxmox-lab-root-ca.crt \
      "$REMOTE_USER@$name:/usr/local/share/ca-certificates/proxmox-lab-root-ca.crt"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$name" "
      set -e
      update-ca-certificates
      systemctl reload pveproxy || systemctl restart pveproxy
    "
  done

  doing "Registering ACME account 'default' against Step CA directory"
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "
    # Deactivate existing account if present (needed after CA regeneration)
    pvenode acme account deactivate default 2>/dev/null || true
    rm -f /etc/pve/priv/acme/default 2>/dev/null || true
    pvenode acme account register default admin@example.com --directory '$ACME_DIR'
  "

  doing "Ordering/renewing certs per node"
  exec 3< <(jq -r '.nodelist | to_entries[] | "\(.key)\t\(.value.ip)"' <<<"$MEMBERS_JSON")
  while IFS=$'\t' read -r name ip <&3; do
    [[ -z "$name" || -z "$ip" ]] && continue
    fqdn="${name}.${DNS_POSTFIX}"
    pmfqdn="proxmox.${DNS_POSTFIX}"
    acme_map="account=default,domains=${fqdn};${pmfqdn}"
    
    info "  - $name ($ip) -> $fqdn (+ ${pmfqdn})"
    
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" "
      set -e
      pvenode config set --acme \"$acme_map\"
      pvenode acme cert order -force
    " || { warn "SSH/ACME failed for $name ($ip)"; continue; }

  done
  exec 3<&-

  success "Root CA installed on all nodes; ACME account configured; certificates ordered per node."
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

function destroyLab() {
  checkProxmox
  doing "Destroying lab..."
  manageVMIDs "${REQUIRED_VMIDS[@]}"
  if docker compose run --rm -it terraform destroy; then
    success "Destruction complete.\n"
  else 
    error "An error occurred during lab destruction"
    exit 1
  fi
  sshRun $REMOTE_USER $PROXMOX_HOST 'bash /root/setup.sh destroy || true'
  sshRun $REMOTE_USER $PROXMOX_HOST 'pvesh set /nodes/pve/dns -dns1 1.1.1.1 -search domain.local'
  sshRun $REMOTE_USER $PROXMOX_HOST 'rm /usr/local/share/ca-certificates/proxmox-lab*.crt || true && update-ca-certificates -v'
  sshRun $REMOTE_USER $PROXMOX_HOST 'pvenode acme account deactivate default > /dev/null &2>1 || true'
  sshRun $REMOTE_USER $PROXMOX_HOST 'rm /etc/pve/priv/acme/default > /dev/null &2>1 || true'
  rm -r packer/packer-outputs
  rm -r terraform/lxc-step-ca/step-ca
  rm hosts.json
  rm proxmox-lab-root-ca.crt
  info "Destruction complete"
}

function runProxmoxSetupOnAll() {
  doing "Running Proxmox setup on all cluster nodes..."

  # Build config JSON from cluster-info.json (includes storage and bridge)
  local CONFIG
  CONFIG=$(cat "$CLUSTER_INFO_FILE")

  # Cluster-wide setup (run once on primary)
  local PRIMARY_IP="${CLUSTER_NODE_IPS[0]}"
  doing "Running cluster-wide Proxmox setup on ${CLUSTER_NODES[0]} ($PRIMARY_IP)..."

  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no proxmox/setup.sh "root@${PRIMARY_IP}:/tmp/proxmox-setup.sh"
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "root@${PRIMARY_IP}" \
    "chmod +x /tmp/proxmox-setup.sh && /tmp/proxmox-setup.sh cluster-init '$CONFIG'"

  # Per-node setup (run on each node) - pass config for storage/bridge settings
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    doing "Running node setup on $node ($ip)..."
    scp -i "$KEY_PATH" -o StrictHostKeyChecking=no proxmox/setup.sh "root@${ip}:/tmp/proxmox-setup.sh"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "root@${ip}" \
      "chmod +x /tmp/proxmox-setup.sh && /tmp/proxmox-setup.sh node-setup '$CONFIG'"
  done

  success "Proxmox setup complete on all nodes"
}

function updateTerraformFromClusterInfo() {
  doing "Updating terraform.tfvars from cluster configuration..."

  local TFVARS_FILE="terraform/terraform.tfvars"

  # Check if cluster-info.json exists
  if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    error "cluster-info.json not found. Run setup again."
    return 1
  fi

  # Load values from cluster-info.json
  local EXT_GW=$(jq -r '.network.external.gateway // ""' "$CLUSTER_INFO_FILE")
  local DNS_START=$(jq -r '.network.external.dns_start_ip // ""' "$CLUSTER_INFO_FILE")
  local SVC_START=$(jq -r '.network.external.services_start_ip // ""' "$CLUSTER_INFO_FILE")
  local INT_CIDR_VAL=$(jq -r '.network.labnet.cidr // ""' "$CLUSTER_INFO_FILE")
  local INT_GW=$(jq -r '.network.labnet.gateway // ""' "$CLUSTER_INFO_FILE")
  local DNS_POSTFIX_VAL=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
  local BRIDGE_VAL=$(jq -r '.network.selected_bridge // "vmbr0"' "$CLUSTER_INFO_FILE")
  local STORAGE_VAL=$(jq -r '.storage.selected // "local-lvm"' "$CLUSTER_INFO_FILE")

  # Copy from example if doesn't exist
  if [ ! -f "$TFVARS_FILE" ]; then
    if [ -f "terraform/terraform.tfvars.example" ]; then
      cp terraform/terraform.tfvars.example "$TFVARS_FILE"
      info "Created terraform.tfvars from example"
    else
      error "terraform.tfvars.example not found"
      return 1
    fi
  fi

  # Helper function for cross-platform sed
  sed_inplace() {
    if sed --version >/dev/null 2>&1; then
      sed -i "$@"
    else
      sed -i '' "$@"
    fi
  }

  # Update network_gateway_address
  sed_inplace "s|^network_gateway_address = .*|network_gateway_address = \"$EXT_GW\"|" "$TFVARS_FILE"
  info "  network_gateway_address = \"$EXT_GW\""

  # Update network_interface_bridge
  sed_inplace "s|^network_interface_bridge = .*|network_interface_bridge = \"$BRIDGE_VAL\"|" "$TFVARS_FILE"
  info "  network_interface_bridge = \"$BRIDGE_VAL\""

  # Update lxc_storage
  if grep -q "^lxc_storage" "$TFVARS_FILE"; then
    sed_inplace "s|^lxc_storage = .*|lxc_storage = \"$STORAGE_VAL\"|" "$TFVARS_FILE"
  else
    echo "" >> "$TFVARS_FILE"
    echo "lxc_storage = \"$STORAGE_VAL\"" >> "$TFVARS_FILE"
  fi
  info "  lxc_storage = \"$STORAGE_VAL\""

  # Update dns_postfix
  sed_inplace "s|^dns_postfix = .*|dns_postfix = \"$DNS_POSTFIX_VAL\"|" "$TFVARS_FILE"
  info "  dns_postfix = \"$DNS_POSTFIX_VAL\""

  # Update dns_primary_ipv4
  sed_inplace "s|^dns_primary_ipv4 = .*|dns_primary_ipv4 = \"$DNS_START\"|" "$TFVARS_FILE"
  info "  dns_primary_ipv4 = \"$DNS_START\""

  # Update step-ca_eth0_ipv4_cidr (service start IP with /24)
  local EXT_CIDR_VAL=$(jq -r '.network.external.cidr // ""' "$CLUSTER_INFO_FILE")
  local CIDR_MASK=$(echo "$EXT_CIDR_VAL" | grep -oE '/[0-9]+$')
  sed_inplace "s|^step-ca_eth0_ipv4_cidr = .*|step-ca_eth0_ipv4_cidr = \"${SVC_START}${CIDR_MASK}\"|" "$TFVARS_FILE"
  info "  step-ca_eth0_ipv4_cidr = \"${SVC_START}${CIDR_MASK}\""

  # Build and update proxmox_node_ips map
  local NODE_IPS_MAP="{\n"
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    [ $i -gt 0 ] && NODE_IPS_MAP+=",\n"
    NODE_IPS_MAP+="  $node = \"$ip\""
  done
  NODE_IPS_MAP+="\n}"

  # Remove existing proxmox_node_ips block and add new
  sed_inplace '/^proxmox_node_ips/,/^}/d' "$TFVARS_FILE"
  echo "" >> "$TFVARS_FILE"
  echo "# Proxmox cluster node IPs (auto-generated by setup.sh)" >> "$TFVARS_FILE"
  echo -e "proxmox_node_ips = $NODE_IPS_MAP" >> "$TFVARS_FILE"
  info "  proxmox_node_ips updated"

  # Build DNS main nodes configuration
  local DNS_MAIN_CONFIG="["
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local hostname="dns-$(printf '%02d' $((i + 1)))"
    # Calculate IP from DNS_START
    local base_ip=$(echo "$DNS_START" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.')
    local start_octet=$(echo "$DNS_START" | grep -oE '[0-9]+$')
    local ip="${base_ip}$((start_octet + i))${CIDR_MASK}"
    [ $i -gt 0 ] && DNS_MAIN_CONFIG+=", "
    DNS_MAIN_CONFIG+="\n  { hostname = \"$hostname\", target_node = \"$node\", ip = \"$ip\", gw = \"$EXT_GW\" }"
  done
  DNS_MAIN_CONFIG+="\n]"

  # Remove and rewrite dns_main_nodes
  sed_inplace '/^dns_main_nodes/,/^\]/d' "$TFVARS_FILE"
  echo "" >> "$TFVARS_FILE"
  echo "# DNS cluster nodes - Main cluster (auto-generated)" >> "$TFVARS_FILE"
  echo -e "dns_main_nodes = $DNS_MAIN_CONFIG" >> "$TFVARS_FILE"
  info "  dns_main_nodes updated"

  # Build DNS labnet nodes configuration (max 2)
  if jq -e '.network.labnet.enabled == true' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    local LABNET_DNS_CONFIG="["
    local labnet_count=$((${#CLUSTER_NODES[@]} < 2 ? ${#CLUSTER_NODES[@]} : 2))
    local labnet_base=$(echo "$INT_GW" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.')
    local labnet_mask=$(echo "$INT_CIDR_VAL" | grep -oE '/[0-9]+$')

    for i in $(seq 0 $((labnet_count - 1))); do
      local node="${CLUSTER_NODES[$i]}"
      local hostname="labnet-dns-$(printf '%02d' $((i + 1)))"
      local ip="${labnet_base}$((3 + i))${labnet_mask}"
      [ $i -gt 0 ] && LABNET_DNS_CONFIG+=", "
      LABNET_DNS_CONFIG+="\n  { hostname = \"$hostname\", target_node = \"$node\", ip = \"$ip\", gw = \"$INT_GW\" }"
    done
    LABNET_DNS_CONFIG+="\n]"

    # Remove and rewrite dns_labnet_nodes
    sed_inplace '/^dns_labnet_nodes/,/^\]/d' "$TFVARS_FILE"
    echo "" >> "$TFVARS_FILE"
    echo "# DNS cluster nodes - Labnet SDN cluster (auto-generated)" >> "$TFVARS_FILE"
    echo -e "dns_labnet_nodes = $LABNET_DNS_CONFIG" >> "$TFVARS_FILE"
    info "  dns_labnet_nodes updated"
  fi

  success "Terraform configuration updated from cluster-info.json"
}

function runEverything() {
  checkRequirements
  generateSSHKeys
  checkProxmox
  installSSHKeys

  # Check if we have existing cluster info
  if [ -f "$CLUSTER_INFO_FILE" ] && jq -e '.network' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    read -rp "$(question "Found existing cluster-info.json. Use it? [Y/n]: ")" USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
    if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
      loadClusterInfo
    else
      detectAndSaveCluster
      configureNetworking
    fi
  else
    # Fresh setup - detect cluster and configure
    detectAndSaveCluster
    configureNetworking
  fi

  # Distribute SSH keys to all cluster nodes
  distributeSSHKeys

  # Select storage and network bridge (updates cluster-info.json)
  selectSharedStorage
  selectNetworkBridge

  # Save storage/bridge selection to cluster-info.json
  local tmp_file=$(mktemp)
  jq --arg storage "$TEMPLATE_STORAGE" \
     --argjson shared "$USE_SHARED_STORAGE" \
     --arg bridge "$NETWORK_BRIDGE" \
     '. + {
       storage: { selected: $storage, is_shared: $shared },
       network: (.network + { selected_bridge: $bridge })
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  # Update terraform.tfvars from cluster-info.json
  updateTerraformFromClusterInfo

  # Run Proxmox setup on all nodes
  runProxmoxSetupOnAll

  # Optional post-install script
  proxmoxPostInstall

  # Deploy services (LXC, Packer, VMs)
  deployServices

  # Setup Docker Swarm
  setupDockerSwarm
}

function runEverythingButSSH() {
  checkRequirements
  checkProxmox

  # Check if we have existing cluster info
  if [ -f "$CLUSTER_INFO_FILE" ] && jq -e '.network' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    read -rp "$(question "Found existing cluster-info.json. Use it? [Y/n]: ")" USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
    if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
      loadClusterInfo
    else
      detectAndSaveCluster
      configureNetworking
    fi
  else
    detectAndSaveCluster
    configureNetworking
  fi

  # Distribute SSH keys to all cluster nodes (assumes keys exist)
  if [ -f "$KEY_PATH" ]; then
    distributeSSHKeys
  fi

  # Select storage and network bridge
  selectSharedStorage
  selectNetworkBridge

  # Save storage/bridge selection to cluster-info.json
  local tmp_file=$(mktemp)
  jq --arg storage "$TEMPLATE_STORAGE" \
     --argjson shared "$USE_SHARED_STORAGE" \
     --arg bridge "$NETWORK_BRIDGE" \
     '. + {
       storage: { selected: $storage, is_shared: $shared },
       network: (.network + { selected_bridge: $bridge })
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  # Update terraform.tfvars from cluster-info.json
  updateTerraformFromClusterInfo

  # Run Proxmox setup on all nodes
  runProxmoxSetupOnAll

  # Optional post-install script
  proxmoxPostInstall

  # Deploy services
  deployServices

  # Setup Docker Swarm
  setupDockerSwarm
}

function manualRollback() {
  cat <<EOF

#############################################################################
Manual Rollback

Select the phase to rollback from:
  1) LXC containers (DNS, step-ca)
  2) Packer templates
  3) VMs (docker-swarm, kasm)
#############################################################################

EOF
  read -rp "$(question "Enter phase number [1-3]: ")" PHASE
  case $PHASE in
    1|2|3) rollbackDeployment "$PHASE";;
    *) error "Invalid phase";;
  esac
}

function showMenu() {
  echo
  echo "=========================================="
  echo "  Proxmox Lab - Main Menu"
  echo "=========================================="
  echo
  echo "  1) New installation"
  echo "  2) New installation - skip SSH key gen"
  echo "  3) Deploy services (Terraform)"
  echo "  4) Deploy Docker Swarm"
  echo "  5) Build DNS records"
  echo "  6) Update root certificates"
  echo "  7) Proxmox post-install (all nodes)"
  echo "  8) Regenerate CA"
  echo "  9) Rollback deployment"
  echo "  10) Destroy lab"
  echo "  0) Exit"
  echo
}

header

while true; do
  showMenu
  read -rp "$(question "Select an option [0-10]: ")" choice

  case $choice in
    1) runEverything;;
    2) runEverythingButSSH;;
    3) deployServices;;
    4) setupDockerSwarm;;
    5) updateDNSRecords;;
    6) updateRootCertificates;;
    7) proxmoxPostInstall;;
    8) regenerateCA;;
    9) manualRollback;;
    10) destroyLab;;
    0|q|Q) warn "Exiting..."; break;;
    *) error "Invalid option: $choice";;
  esac

  echo
  read -rp "Press Enter to continue..."
done
