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
function sshRun()       { ssh -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "$1@$2" "$3"; }
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
        -target=module.nomad \
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

      # Also clean up any LXC VMIDs that might be orphaned (dns + step-ca)
      for VMID in 902 909 910 911 912 920 921 922; do
        ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" \
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
    if ! ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "$REMOTE_USER@$ip" \
      "curl -s --connect-timeout 5 https://install.pi-hole.net >/dev/null 2>&1 || ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1" 2>/dev/null; then
      failed_nodes+=("$node ($ip)")

      # Get DNS configuration for this node
      local dns_info
      dns_info=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
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
    dns_json=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
      "pvesh get /nodes/$node/dns --output-format json 2>/dev/null" || echo "{}")

    dns1=$(echo "$dns_json" | jq -r '.dns1 // ""')
    dns2=$(echo "$dns_json" | jq -r '.dns2 // ""')
    search=$(echo "$dns_json" | jq -r '.search // ""')

    # Test connectivity
    local connectivity="unknown"
    if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "$REMOTE_USER@$ip" \
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
        ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
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
    if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
      "test -f /var/lib/vz/template/cache/${TEMPLATE}" 2>/dev/null; then
      info "  $node: Template already exists"
    else
      doing "  $node: Downloading template..."
      if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
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
    TEMPLATE_STORAGE_TYPE=$(jq -r '.storage.type // "lvm"' "$CLUSTER_INFO_FILE")
    if [ -n "$EXISTING_STORAGE" ] && [ "$EXISTING_STORAGE" != "null" ]; then
      TEMPLATE_STORAGE="$EXISTING_STORAGE"
      USE_SHARED_STORAGE=$(jq -r '.storage.is_shared // false' "$CLUSTER_INFO_FILE")
      export TEMPLATE_STORAGE
      export TEMPLATE_STORAGE_TYPE
      export USE_SHARED_STORAGE
      success "Using configured storage: $TEMPLATE_STORAGE ($TEMPLATE_STORAGE_TYPE, shared: $USE_SHARED_STORAGE)"
      return 0
    fi
  fi

  doing "Detecting available storage..."

  # Get storage list from first node
  local STORAGE_JSON
  STORAGE_JSON=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "pvesh get /storage --output-format json")

  # Build arrays of storage info (name, type, shared)
  local STORAGE_NAMES=()
  local STORAGE_TYPES=()
  local STORAGE_SHARED=()

  # For clusters: only show shared storage that supports VM images
  # For single-node: show all storage that supports VM images
  local JQ_FILTER
  if [ "$IS_CLUSTER" = "true" ]; then
    JQ_FILTER='.[] | select(.shared == 1 and (.content | contains("images")))'
  else
    JQ_FILTER='.[] | select(.content | contains("images"))'
  fi

  while IFS='|' read -r name type shared; do
    if [[ -n "$name" ]]; then
      STORAGE_NAMES+=("$name")
      STORAGE_TYPES+=("${type:-unknown}")
      STORAGE_SHARED+=("$shared")
    fi
  done < <(echo "$STORAGE_JSON" | jq -r "$JQ_FILTER | \"\(.storage)|\(.type // \"unknown\")|\(.shared // 0)\"")

  if [ ${#STORAGE_NAMES[@]} -gt 0 ]; then
    echo
    info "Storage Selection for VM Templates"
    if [ "$IS_CLUSTER" = "true" ]; then
      info "Multi-node cluster detected - showing shared storage only"
    fi
    echo
    info "Available storage:"
    for i in "${!STORAGE_NAMES[@]}"; do
      local shared_label=""
      if [ "${STORAGE_SHARED[$i]}" = "1" ]; then
        shared_label="[shared]"
      else
        shared_label="[local]"
      fi
      echo "    $((i + 1)). ${STORAGE_NAMES[$i]} (${STORAGE_TYPES[$i]}) $shared_label"
    done
    echo

    local DEFAULT_STORE="${STORAGE_NAMES[0]}"
    read -rp "$(question "Select storage [1]: ")" STORAGE_CHOICE
    STORAGE_CHOICE=${STORAGE_CHOICE:-1}

    # Check if user entered a number or a name
    if [[ "$STORAGE_CHOICE" =~ ^[0-9]+$ ]]; then
      local idx=$((STORAGE_CHOICE - 1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#STORAGE_NAMES[@]}" ]; then
        TEMPLATE_STORAGE="${STORAGE_NAMES[$idx]}"
        TEMPLATE_STORAGE_TYPE="${STORAGE_TYPES[$idx]}"
        USE_SHARED_STORAGE=$([ "${STORAGE_SHARED[$idx]}" = "1" ] && echo true || echo false)
      else
        error "Invalid selection"
        return 1
      fi
    else
      # Assume they typed the storage name - look it up
      local found=false
      for i in "${!STORAGE_NAMES[@]}"; do
        if [ "${STORAGE_NAMES[$i]}" = "$STORAGE_CHOICE" ]; then
          TEMPLATE_STORAGE="${STORAGE_NAMES[$i]}"
          TEMPLATE_STORAGE_TYPE="${STORAGE_TYPES[$i]}"
          USE_SHARED_STORAGE=$([ "${STORAGE_SHARED[$i]}" = "1" ] && echo true || echo false)
          found=true
          break
        fi
      done
      if [ "$found" = false ]; then
        error "Storage '$STORAGE_CHOICE' not found"
        return 1
      fi
    fi
  else
    if [ "$IS_CLUSTER" = "true" ]; then
      error "No shared storage found! Multi-node clusters require shared storage (NFS, Ceph, etc.)"
      error "Please configure shared storage in Proxmox before continuing."
      return 1
    else
      warn "No VM-compatible storage found. Using local-lvm"
      TEMPLATE_STORAGE="local-lvm"
      TEMPLATE_STORAGE_TYPE="lvm"
      USE_SHARED_STORAGE=false
    fi
  fi

  export TEMPLATE_STORAGE
  export TEMPLATE_STORAGE_TYPE
  export USE_SHARED_STORAGE
  success "Using storage: $TEMPLATE_STORAGE ($TEMPLATE_STORAGE_TYPE, shared: $USE_SHARED_STORAGE)"
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
    done < <(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
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

# ============================================
# Deployment Helper Functions
# ============================================

# Ensures cluster context is loaded (cluster-info.json, PROXMOX_HOST set)
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

# Ensures shared storage is selected for multi-node clusters
function ensureSharedStorage() {
  if [ -z "$TEMPLATE_STORAGE" ]; then
    selectSharedStorage || return 1
  fi

  # For clusters, verify shared storage is selected
  if [ "$IS_CLUSTER" = "true" ] && [ "$USE_SHARED_STORAGE" != "true" ]; then
    warn "Multi-node cluster requires shared storage. Current: $TEMPLATE_STORAGE (local)"
    warn "You need to select shared storage (NFS, Ceph, etc.)"
    echo

    # Clear existing storage config to force re-selection
    TEMPLATE_STORAGE=""
    TEMPLATE_STORAGE_TYPE=""
    USE_SHARED_STORAGE=""

    # Remove storage from cluster-info.json to allow re-selection
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      local tmp_file=$(mktemp)
      jq 'del(.storage)' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"
    fi

    # Now run storage selection (won't skip because we cleared it)
    selectSharedStorage || return 1

    # Save the new storage config
    local tmp_file=$(mktemp)
    jq --arg storage "$TEMPLATE_STORAGE" \
       --arg storage_type "${TEMPLATE_STORAGE_TYPE:-lvm}" \
       --argjson shared "$USE_SHARED_STORAGE" \
       '. + { storage: { selected: $storage, type: $storage_type, is_shared: $shared } }' \
       "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"
  fi

  info "Using storage: $TEMPLATE_STORAGE ($TEMPLATE_STORAGE_TYPE)"
}

# Verifies DNS and CA are deployed and accessible
function ensureCriticalServices() {
  if [ ! -f "hosts.json" ]; then
    error "hosts.json not found. Deploy critical services first (option 4)."
    return 1
  fi

  local DNS_IP CA_IP
  DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -z "$DNS_IP" ] || [ "$DNS_IP" = "null" ]; then
    error "DNS not deployed. Run option 4 (Deploy critical services) first."
    return 1
  fi

  if [ -z "$CA_IP" ] || [ "$CA_IP" = "null" ]; then
    error "CA not deployed. Run option 4 (Deploy critical services) first."
    return 1
  fi

  doing "Verifying critical services..."
  success "DNS ($DNS_IP) and CA ($CA_IP) found"
  return 0
}

# Verifies a Packer template exists
# Parameters: vmid, template_name
function ensureTemplate() {
  local vmid="$1"
  local template_name="$2"

  doing "Checking for $template_name (VM $vmid)..."
  if ! ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
       "$REMOTE_USER@$PROXMOX_HOST" "qm config $vmid" &>/dev/null; then
    error "$template_name (VM $vmid) not found!"
    return 1
  fi
  success "$template_name found"
  return 0
}

# Updates Packer config with current storage settings
function updatePackerStorageConfig() {
  local config="packer/packer.auto.pkrvars.hcl"
  if [ -f "$config" ]; then
    doing "Updating Packer storage config..."
    grep -v "^template_storage" "$config" > "${config}.tmp" || true
    mv "${config}.tmp" "$config"
    echo "template_storage = \"$TEMPLATE_STORAGE\"" >> "$config"
    echo "template_storage_type = \"$TEMPLATE_STORAGE_TYPE\"" >> "$config"
    success "Packer config updated: storage=$TEMPLATE_STORAGE, type=$TEMPLATE_STORAGE_TYPE"
  else
    warn "Packer config not found at $config"
  fi
}

# Migrates a template disk to the appropriate storage based on deployment type
# Parameters: vmid
# NOTE: Packer proxmox-clone builder does NOT support specifying target storage for cloned disks.
#       Adding a "disks" block in Packer ADDS a new disk instead of configuring the cloned disk.
#       This function must be called AFTER Packer build to move the disk to the correct storage.
#       - For clusters: moves to selected shared storage (TEMPLATE_STORAGE)
#       - For single-node: moves to local-lvm
function migrateTemplateToSharedStorage() {
  local vmid="$1"

  # Determine target storage based on deployment type
  local target_storage
  if [ "$IS_CLUSTER" = "true" ] && [ "$USE_SHARED_STORAGE" = "true" ]; then
    target_storage="$TEMPLATE_STORAGE"
  else
    target_storage="local-lvm"
  fi

  doing "Checking template $vmid disk location..."

  # Get current disk storage (format: "storage:volume,options")
  local disk_line
  disk_line=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" \
    "qm config $vmid 2>/dev/null | grep -E '^scsi0:'" || echo "")

  if [ -z "$disk_line" ]; then
    warn "Template $vmid not found or has no scsi0 disk, skipping migration"
    return 0
  fi

  # Extract storage name (everything after "scsi0: " and before ":")
  local current_storage
  current_storage=$(echo "$disk_line" | sed 's/^scsi0: *//' | cut -d: -f1)

  info "Current disk storage: $current_storage"
  info "Target storage: $target_storage"

  if [ "$current_storage" = "$target_storage" ]; then
    success "Template $vmid disk already on $target_storage"
    return 0
  fi

  doing "Moving template $vmid disk from $current_storage to $target_storage..."

  # Move the disk to target storage (--delete 1 removes the source after copy)
  local move_output
  move_output=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" \
    "qm move_disk $vmid scsi0 $target_storage --delete 1 2>&1")
  local move_result=$?

  if [ $move_result -eq 0 ]; then
    success "Template $vmid disk migrated to $target_storage"

    # Verify the move succeeded
    local new_disk_line
    new_disk_line=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" \
      "qm config $vmid 2>/dev/null | grep -E '^scsi0:'" || echo "")
    local new_storage
    new_storage=$(echo "$new_disk_line" | sed 's/^scsi0: *//' | cut -d: -f1)

    if [ "$new_storage" = "$target_storage" ]; then
      success "Verified: disk is now on $target_storage"
    else
      warn "Verification failed: disk appears to still be on $new_storage"
    fi
  else
    error "Failed to migrate template $vmid disk to $target_storage"
    error "Output: $move_output"
    return 1
  fi
  return 0
}

# Removes an existing template VM if it exists
# Parameters: vmid, template_name
function removeTemplateIfExists() {
  local vmid="$1"
  local template_name="${2:-template}"

  doing "Checking for existing $template_name (VM $vmid)..."
  if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" \
    "qm config $vmid" &>/dev/null; then
    warn "$template_name (VM $vmid) already exists, removing..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" \
      "qm destroy $vmid --purge" || true
    success "Existing template removed"
  fi
}

# Generic function for deploying Nomad jobs
# Parameters: job_name, job_file, [storage_path]
function deployNomadJob() {
  local job_name="$1"
  local job_file="$2"
  local storage_path="${3:-}"
  local VM_USER="labadmin"

  ensureClusterContext || return 1

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  if [ -z "$NOMAD_IP" ] || [ "$NOMAD_IP" = "null" ]; then
    error "No Nomad nodes found in hosts.json. Deploy Nomad first (option 5)."
    return 1
  fi

  if [ ! -f "$job_file" ]; then
    error "Job file not found: $job_file"
    return 1
  fi

  doing "Deploying $job_name to Nomad cluster..."

  # Create storage directory if specified
  if [ -n "$storage_path" ]; then
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$VM_USER@$NOMAD_IP" \
      "sudo mkdir -p $storage_path" || true
  fi

  # Render template with environment variables
  export DNS_POSTFIX
  envsubst '${DNS_POSTFIX}' < "$job_file" > "/tmp/${job_name}-rendered.nomad.hcl"

  # Copy to Nomad node
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "/tmp/${job_name}-rendered.nomad.hcl" "$VM_USER@$NOMAD_IP:/tmp/${job_name}.nomad.hcl"

  # Run the job
  if ! ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$VM_USER@$NOMAD_IP" \
    "nomad job run /tmp/${job_name}.nomad.hcl"; then
    error "Failed to deploy $job_name"
    return 1
  fi

  # Wait for deployment and show status
  doing "Waiting for $job_name deployment..."
  sleep 5
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$VM_USER@$NOMAD_IP" \
    "nomad job status $job_name | head -25"

  success "$job_name deployed successfully!"
  return 0
}

# Refreshes hosts.json with actual VM IPs from Proxmox QEMU guest agent
# This resolves DHCP IP mismatches after VM deployment
function refreshHostsJsonFromProxmox() {
  local vm_prefix="${1:-nomad}"
  local vmid_start="${2:-905}"
  local vmid_end="${3:-907}"
  local max_wait="${4:-120}"  # Max seconds to wait for guest agent

  doing "Refreshing hosts.json with actual VM IPs from Proxmox..."

  # Query each Proxmox node for VM IPs
  local updated_hosts=()
  for vmid in $(seq $vmid_start $vmid_end); do
    local vm_name=""
    local vm_ip=""
    local found_node_ip=""

    # Try each node to find the VM
    for node_ip in "${CLUSTER_NODE_IPS[@]}"; do
      # Check if VM exists on this node
      local vm_config
      vm_config=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
        "$REMOTE_USER@$node_ip" "qm config $vmid 2>/dev/null" || echo "")

      if [ -n "$vm_config" ]; then
        vm_name=$(echo "$vm_config" | grep "^name:" | awk '{print $2}')
        found_node_ip="$node_ip"
        break
      fi
    done

    # If VM found, wait for guest agent to be ready
    if [ -n "$vm_name" ] && [ -n "$found_node_ip" ]; then
      info "Waiting for QEMU guest agent on $vm_name ($vmid)..."
      local elapsed=0
      local interval=5

      while [ $elapsed -lt $max_wait ]; do
        vm_ip=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
          "$REMOTE_USER@$found_node_ip" "qm guest cmd $vmid network-get-interfaces 2>/dev/null | jq -r '.[].\"ip-addresses\"[]? | select(.\"ip-address-type\"==\"ipv4\" and (.\"ip-address\" | startswith(\"10.\"))) | .\"ip-address\"' 2>/dev/null | head -1" || echo "")

        if [ -n "$vm_ip" ]; then
          success "Found $vm_name ($vmid): $vm_ip"
          updated_hosts+=("{\"hostname\":\"$vm_name\",\"ip\":\"$vm_ip\"}")
          break
        fi

        printf "  Waiting for guest agent... (%ds/%ds)\r" "$elapsed" "$max_wait"
        sleep $interval
        elapsed=$((elapsed + interval))
      done

      if [ -z "$vm_ip" ]; then
        warn "Timeout waiting for guest agent on $vm_name ($vmid)"
      fi
    fi
  done

  # Update hosts.json with the new IPs
  if [ ${#updated_hosts[@]} -gt 0 ]; then
    # Read existing hosts.json
    local existing_external
    existing_external=$(jq -c '[.external[] | select(.hostname | startswith("'$vm_prefix'") | not)]' hosts.json 2>/dev/null || echo "[]")

    local existing_internal
    existing_internal=$(jq -c '.internal // []' hosts.json 2>/dev/null || echo "[]")

    # Combine existing non-VM hosts with new VM hosts
    local new_hosts_json
    new_hosts_json=$(printf '%s\n' "${updated_hosts[@]}" | jq -s '.')

    # Merge and write back
    jq -n --argjson existing "$existing_external" \
          --argjson new "$new_hosts_json" \
          --argjson internal "$existing_internal" \
          '{external: ($existing + $new), internal: $internal}' > hosts.json

    success "hosts.json updated with actual VM IPs"
    jq -r '.external[] | select(.hostname | startswith("'$vm_prefix'")) | "  - \(.hostname): \(.ip)"' hosts.json
  else
    warn "No VM IPs found via guest agent. hosts.json not updated."
    return 1
  fi
}

# ============================================
# End Deployment Helper Functions
# ============================================

# Comprehensive cluster-wide resource purge
# Scans all Proxmox nodes for project VMs/LXCs and offers to destroy them
function purgeClusterResources() {
  local AUTO_PURGE=false
  local PURGE_TERRAFORM=true
  local LXC_ONLY=false
  local INCLUDE_TEMPLATES=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto) AUTO_PURGE=true; shift ;;
      --no-terraform) PURGE_TERRAFORM=false; shift ;;
      --lxc-only) LXC_ONLY=true; shift ;;
      --include-templates) INCLUDE_TEMPLATES=true; shift ;;
      *) shift ;;
    esac
  done

  doing "Scanning all cluster nodes for existing project resources..."

  # Ensure cluster info is loaded
  if [ ${#CLUSTER_NODE_IPS[@]} -eq 0 ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      loadClusterInfo
    else
      error "No cluster information available. Run setup first."
      return 1
    fi
  fi

  # Define project VMID ranges
  # LXC containers
  local LXC_VMIDS=(
    902         # step-ca (legacy)
    909         # step-ca
    910 911 912 # dns-main (dns-01, dns-02, dns-03)
    920 921 922 # dns-labnet (labnet-dns-01, labnet-dns-02, labnet-dns-03)
  )

  # QEMU VMs (excluding Packer templates - handled separately)
  local VM_VMIDS=(
    903 904           # docker-swarm managers
    905 906 907       # nomad cluster
    908 930           # kasm
  )

  # Packer templates (separate so user can choose)
  local TEMPLATE_VMIDS=(
    9001              # docker-template
    9002              # nomad-template
  )

  # Collect findings
  local FOUND_LXC=()
  local FOUND_VM=()
  local FOUND_TEMPLATES=()
  local FOUND_NODES=()

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    info "  Scanning $node ($ip)..."

    # Check LXC containers
    for vmid in "${LXC_VMIDS[@]}"; do
      if ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
         "$REMOTE_USER@$ip" "pct status $vmid" &>/dev/null 2>&1; then
        local name
        name=$(ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
               "$REMOTE_USER@$ip" "pct config $vmid 2>/dev/null | grep -oP 'hostname: \K.*'" 2>/dev/null || echo "unknown")
        FOUND_LXC+=("$vmid|$node|$ip|$name")
      fi
    done

    # Check QEMU VMs (skip if --lxc-only)
    if [ "$LXC_ONLY" != "true" ]; then
      for vmid in "${VM_VMIDS[@]}"; do
        if ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
           "$REMOTE_USER@$ip" "qm status $vmid" &>/dev/null 2>&1; then
          local name
          name=$(ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                 "$REMOTE_USER@$ip" "qm config $vmid 2>/dev/null | grep -oP 'name: \K.*'" 2>/dev/null || echo "unknown")
          FOUND_VM+=("$vmid|$node|$ip|$name")
        fi
      done

      # Check Packer templates (only add if not already found - shared storage means one copy)
      for vmid in "${TEMPLATE_VMIDS[@]}"; do
        # Skip if we already found this template on another node
        local already_found=false
        if [ ${#FOUND_TEMPLATES[@]} -gt 0 ]; then
          for entry in "${FOUND_TEMPLATES[@]}"; do
            [[ "$entry" == "$vmid|"* ]] && already_found=true && break
          done
        fi
        [ "$already_found" = true ] && continue

        if ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
           "$REMOTE_USER@$ip" "qm status $vmid" &>/dev/null 2>&1; then
          local name
          name=$(ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                 "$REMOTE_USER@$ip" "qm config $vmid 2>/dev/null | grep -oP 'name: \K.*'" 2>/dev/null || echo "unknown")
          FOUND_TEMPLATES+=("$vmid|$node|$ip|$name")
        fi
      done
    fi
  done

  # Report findings
  local total_found=$(( ${#FOUND_LXC[@]} + ${#FOUND_VM[@]} ))
  local total_with_templates=$(( total_found + ${#FOUND_TEMPLATES[@]} ))

  if [ $total_with_templates -eq 0 ]; then
    success "No existing project resources found on cluster"
    return 0
  fi

  echo
  warn "Found $total_with_templates existing project resource(s):"
  echo

  if [ ${#FOUND_LXC[@]} -gt 0 ]; then
    echo "  LXC Containers:"
    printf "  %-8s %-12s %-15s %s\n" "VMID" "Node" "IP" "Hostname"
    printf "  %-8s %-12s %-15s %s\n" "----" "----" "--" "--------"
    for entry in "${FOUND_LXC[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      printf "  %-8s %-12s %-15s %s\n" "$vmid" "$node" "$ip" "$name"
    done
    echo
  fi

  if [ ${#FOUND_VM[@]} -gt 0 ]; then
    echo "  QEMU VMs:"
    printf "  %-8s %-12s %-15s %s\n" "VMID" "Node" "IP" "Name"
    printf "  %-8s %-12s %-15s %s\n" "----" "----" "--" "----"
    for entry in "${FOUND_VM[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      printf "  %-8s %-12s %-15s %s\n" "$vmid" "$node" "$ip" "$name"
    done
    echo
  fi

  if [ ${#FOUND_TEMPLATES[@]} -gt 0 ]; then
    echo "  Packer Templates:"
    printf "  %-8s %-12s %-15s %s\n" "VMID" "Node" "IP" "Name"
    printf "  %-8s %-12s %-15s %s\n" "----" "----" "--" "----"
    for entry in "${FOUND_TEMPLATES[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      printf "  %-8s %-12s %-15s %s\n" "$vmid" "$node" "$ip" "$name"
    done
    echo
  fi

  # Confirm purge of LXC/VMs
  local do_purge=false
  if [ "$AUTO_PURGE" = true ]; then
    do_purge=true
  else
    if [ $total_found -gt 0 ]; then
      read -rp "$(question "Destroy LXC containers and VMs? [y/N]: ")" confirm
      [[ "$confirm" =~ ^[Yy]$ ]] && do_purge=true
    fi
  fi

  # Prompt for template removal (separate decision)
  local do_purge_templates=false
  if [ ${#FOUND_TEMPLATES[@]} -gt 0 ]; then
    if [ "$INCLUDE_TEMPLATES" = true ]; then
      do_purge_templates=true
    elif [ "$AUTO_PURGE" != true ]; then
      read -rp "$(question "Also remove Packer templates (9001, 9002)? These take time to rebuild. [y/N]: ")" confirm_templates
      [[ "$confirm_templates" =~ ^[Yy]$ ]] && do_purge_templates=true
    fi
  fi

  if [ "$do_purge" = false ] && [ "$do_purge_templates" = false ]; then
    warn "Skipping purge. Existing resources may cause deployment conflicts."
    return 1
  fi

  # Purge LXC containers
  if [ "$do_purge" = true ] && [ ${#FOUND_LXC[@]} -gt 0 ]; then
    doing "Destroying LXC containers..."
    for entry in "${FOUND_LXC[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      info "  Destroying LXC $vmid ($name) on $node..."
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$REMOTE_USER@$ip" "pct stop $vmid 2>/dev/null || true; pct destroy $vmid --purge 2>/dev/null || pct destroy $vmid 2>/dev/null || true"
    done
  fi

  # Purge QEMU VMs
  if [ "$do_purge" = true ] && [ ${#FOUND_VM[@]} -gt 0 ]; then
    doing "Destroying QEMU VMs..."
    for entry in "${FOUND_VM[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      info "  Destroying VM $vmid ($name) on $node..."
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$REMOTE_USER@$ip" "qm stop $vmid 2>/dev/null || true; qm destroy $vmid --purge 2>/dev/null || qm destroy $vmid 2>/dev/null || true"
    done
  fi

  # Purge Packer templates
  if [ "$do_purge_templates" = true ] && [ ${#FOUND_TEMPLATES[@]} -gt 0 ]; then
    doing "Destroying Packer templates..."
    for entry in "${FOUND_TEMPLATES[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      info "  Destroying template $vmid ($name) on $node..."
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$REMOTE_USER@$ip" "qm stop $vmid 2>/dev/null || true; qm destroy $vmid --purge 2>/dev/null || qm destroy $vmid 2>/dev/null || true"
    done
  fi

  # Clean Terraform state
  if [ "$PURGE_TERRAFORM" = true ] && [ "$do_purge" = true ]; then
    doing "Cleaning Terraform state..."
    (
      cd terraform
      # Remove all tracked resources from state
      docker compose run --rm terraform state list 2>/dev/null | while read -r resource; do
        docker compose run --rm terraform state rm "$resource" 2>/dev/null || true
      done
    ) 2>/dev/null || true
    info "  Terraform state cleared"
  fi

  # Clear hosts.json entries for destroyed resources
  if [ "$do_purge" = true ] && [ -f "hosts.json" ]; then
    doing "Cleaning hosts.json..."
    # Keep only entries that weren't destroyed
    local tmp_hosts
    tmp_hosts=$(mktemp)
    jq '{
      external: [.external[] | select(.hostname | test("^(dns-|nomad|docker|kasm|step-ca)") | not)],
      internal: [.internal[] | select(.hostname | test("^(labnet-dns-)") | not)]
    }' hosts.json > "$tmp_hosts" 2>/dev/null && mv "$tmp_hosts" hosts.json || rm -f "$tmp_hosts"
  fi

  # Report what was purged
  local purged_count=0
  [ "$do_purge" = true ] && purged_count=$total_found
  [ "$do_purge_templates" = true ] && purged_count=$((purged_count + ${#FOUND_TEMPLATES[@]}))

  if [ $purged_count -gt 0 ]; then
    success "Purged $purged_count resource(s) from cluster"
    [ "$do_purge_templates" = true ] && info "  (including Packer templates)"
  fi
  echo
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
  if ! sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 "$REMOTE_USER@$PROXMOX_HOST" "echo SSH connection successful" >/dev/null 2>&1; then
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

function proxmoxLabInstall() {
  doing "Running Proxmox VE Lab Install Script..."
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ./proxmox/setup.sh "$REMOTE_USER@$PROXMOX_HOST":/root/
  #sshRun $REMOTE_USER $PROXMOX_HOST 'bash -c "chmod +x /root/setup.sh && /root/setup.sh"'
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$PROXMOX_HOST" 'bash -c "chmod +x /root/setup.sh && /root/setup.sh"'
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

function deployAllServices() {
  cat <<EOF

############################################################################
Full Services Deployment

Deploying all services: Pi-hole DNS with Unbound (DNS-over-TLS),
Certificate Authority (Step-CA), Nomad cluster, and Kasm Workspaces.
#############################################################################

EOF

  # Check for and purge existing resources before deployment
  if ! purgeClusterResources; then
    read -rp "$(question "Continue deployment anyway? Resources may conflict. [y/N]: ")" confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && warn "Deployment cancelled" && return 1
  fi

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

  # Check if DNS is already deployed (skip password prompt if so)
  local DNS_ALREADY_DEPLOYED=false
  if [ -f "hosts.json" ]; then
    local DNS_IP
    DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    if [ -n "$DNS_IP" ] && [ "$DNS_IP" != "null" ]; then
      DNS_ALREADY_DEPLOYED=true
      info "DNS already deployed at $DNS_IP"
    fi
  fi

  # Only prompt for Pi-hole password if DNS is not already deployed
  if [ "$DNS_ALREADY_DEPLOYED" = "false" ]; then
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
  else
    # DNS exists, use existing password from terraform.tfvars
    if [ -f "terraform/terraform.tfvars" ]; then
      PIHOLE_PASSWORD=$(grep "^pihole_admin_password" terraform/terraform.tfvars | cut -d'"' -f2)
    fi
    info "Using existing DNS deployment, skipping password prompt"
  fi

  # Load cluster info if not already loaded
  if [ ${#CLUSTER_NODES[@]} -eq 0 ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      loadClusterInfo
    else
      detectClusterNodes
    fi
  fi

  # Skip LXC deployment if DNS and CA already exist
  if [ "$DNS_ALREADY_DEPLOYED" = "true" ]; then
    info "Skipping LXC deployment - DNS and CA already deployed"
    info "Proceeding directly to Packer/VM phases..."
    DEPLOY_PHASE=1
  else
    # Update the step-ca installation script with DNS postfix
    if sed --version >/dev/null 2>&1; then
        sed -i "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
    else
        sed -i '' "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
    fi
    success "Step-CA installation script updated"

    # Generate certificates
    generateCertificates

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
  fi  # End of DNS_ALREADY_DEPLOYED=false block

  # Storage selection for multi-node clusters
  ensureSharedStorage || return 1
  updatePackerStorageConfig

  # Check if templates already exist
  local TEMPLATES_EXIST=false
  if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
       "$REMOTE_USER@$PROXMOX_HOST" "qm config 9001" &>/dev/null && \
     ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
       "$REMOTE_USER@$PROXMOX_HOST" "qm config 9002" &>/dev/null; then
    TEMPLATES_EXIST=true
  fi

  # ============================================
  # PHASE 2: Build Packer Templates
  # ============================================
  if [ "$TEMPLATES_EXIST" = "true" ] && [ "$DNS_ALREADY_DEPLOYED" = "true" ]; then
    info "Skipping Packer build - templates already exist (9001, 9002)"
    DEPLOY_PHASE=2
  else
    cat <<EOF

#############################################################################
Template Creation

Building VM templates with Packer. DNS and CA are now available.
#############################################################################
EOF
    pressAnyKey

    # Check for existing templates and remove them
    removeTemplateIfExists 9001 "docker-template"
    removeTemplateIfExists 9002 "nomad-template"

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

    # Migrate template disks to shared storage for multi-node cloning
    migrateTemplateToSharedStorage 9001
    migrateTemplateToSharedStorage 9002
  fi  # End of TEMPLATES_EXIST=false block

  # ============================================
  # PHASE 3: Deploy VMs (nomad, kasm)
  # ============================================
  cat <<EOF

#############################################################################
VM Deployment

Deploying Nomad cluster and Kasm VMs from templates.
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

  DEPLOY_PHASE=3
  success "Phase 3 complete: VMs deployed"

  # Terraform outputs often have stale IPs for DHCP VMs
  # Query Proxmox directly via QEMU guest agent for actual IPs
  refreshHostsJsonFromProxmox "nomad" 905 907
  refreshHostsJsonFromProxmox "kasm" 930 930 || true  # Kasm is optional, don't fail if not deployed

  # Update DNS records with actual IPs
  updateDNSRecords

  # Configure Nomad cluster (GlusterFS + cluster formation)
  setupNomadCluster

  success "Deployment complete!"
}

# Deploy only critical services (DNS and CA) - no VMs
function deployCriticalServicesOnly() {
  cat <<EOF

############################################################################
Critical Services Deployment

Deploying critical infrastructure only: Pi-hole DNS with Unbound (DNS-over-TLS)
and Certificate Authority (Step-CA). No VMs will be deployed.
#############################################################################

EOF

  # Check for and purge existing LXC resources before deployment
  if ! purgeClusterResources --lxc-only; then
    read -rp "$(question "Continue deployment anyway? Resources may conflict. [y/N]: ")" confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && warn "Deployment cancelled" && return 1
  fi

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

  # Prompt for Pi-hole password
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
Pi-hole admin pass:       [set]
======================================

EOF

  read -rp "$(question "Proceed with critical services deployment? [Y/n]: ")" CONFIRM
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

  # Verify all nodes can reach the internet
  if ! checkClusterConnectivity; then
    error "Cannot proceed without internet connectivity on all nodes."
    return 1
  fi

  # Ensure LXC templates are available on all nodes
  if ! ensureLXCTemplates; then
    error "Cannot proceed without LXC templates on all nodes."
    return 1
  fi

  # Deploy LXC containers (DNS, step-ca)
  cat <<EOF

#############################################################################
LXC Container Deployment

Deploying critical infrastructure: DNS servers and Certificate Authority.
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
    error "LXC container deployment failed"
    read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
    DO_ROLLBACK=${DO_ROLLBACK:-Y}
    if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
      rollbackDeployment 1
    fi
    return 1
  fi

  success "LXC containers deployed"

  # Refresh terraform state
  doing "Refreshing Terraform state..."
  docker compose run --rm -T terraform refresh -target=module.dns-main -target=module.dns-labnet -target=module.step-ca >/dev/null 2>&1 || true

  # Generate hosts.json
  doing "Generating hosts.json..."
  if docker compose run --rm -T terraform output -json host-records > hosts.json 2>&1; then
    if jq -e '.external' hosts.json >/dev/null 2>&1; then
      success "hosts.json generated"
    else
      warn "hosts.json contains invalid data, recreating..."
      generateHostsJsonFromModules
    fi
  else
    warn "Could not generate hosts.json, using module outputs..."
    generateHostsJsonFromModules
  fi

  updateDNSRecords
  updateRootCertificates

  success "Critical services deployment complete!"

  cat <<EOF

#############################################################################
Critical Services Deployed

DNS servers and Certificate Authority are now running.
You can now deploy Nomad (option 5), Kasm (option 6), or both.
#############################################################################
EOF
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
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$INSTALL_SCRIPT" "$REMOTE_USER@$PROXMOX_HOST":/root/install.sh

  doing "Creating LXC container ${TEMPLATE_VMID} (${TEMPLATE_NAME})..."
  local OSTEMPLATE=$(sshRun $REMOTE_USER $PROXMOX_HOST "pveam list local | awk '/vztmpl/ {print \$1; exit}'")
  echo $OSTEMPLATE
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$PROXMOX_HOST" "\
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
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" "\
    pct push ${TEMPLATE_VMID} /root/install.sh /root/install.sh && \
    pct exec ${TEMPLATE_VMID} -- bash -c 'bash /root/install.sh'" || true

  doing "Cleaning container for template..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$PROXMOX_HOST" "pct exec ${TEMPLATE_VMID} -- bash -c 'apt-get clean && \
    rm -rf /tmp/* /var/tmp/* /var/log/* /root/.bash_history && \
    truncate -s 0 /etc/machine-id && \
    rm -f /etc/ssh/ssh_host_* && \
    ssh-keygen -A && \
    systemctl enable ssh'"

  doing "Stopping container and converting to template..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$PROXMOX_HOST" "pct stop ${TEMPLATE_VMID} && pct template ${TEMPLATE_VMID} && pct set ${TEMPLATE_VMID} -ostype debian"
  success "LXC template '${TEMPLATE_NAME}' created successfully"
}

function setupNomadCluster() {
  BRICK="/data/gluster/nomad-data"
  VOL="nomad-data"
  MOUNTPOINT="/srv/gluster/${VOL}"
  # Use labadmin user for Nomad VMs (set by cloud-init)
  local VM_USER="labadmin"

  doing "Setting up Nomad cluster"
  NODE_IPS=()
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && NODE_IPS+=("$ip")
  done < <(
    jq -r '.external[] | select(.hostname | contains("nomad")) | .ip' hosts.json \
    | sed 's:/.*$::'
  )

  if ((${#NODE_IPS[@]} < 1)); then
    echo "No Nomad hosts found to configure."
    return 1
  fi

  if ((${#NODE_IPS[@]} < 3)); then
    warn "Expected 3 Nomad nodes, found ${#NODE_IPS[@]}. Some operations may fail."
  fi

  MGR="${NODE_IPS[0]}"
  ND1="${NODE_IPS[1]:-$MGR}"
  ND2="${NODE_IPS[2]:-$MGR}"

  # Verify connectivity to all nodes first
  doing "Verifying SSH connectivity to Nomad nodes..."
  for ip in "${NODE_IPS[@]}"; do
    if ! ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "$VM_USER@$ip" "hostname" &>/dev/null; then
      error "Cannot connect to $ip as $VM_USER"
      return 1
    fi
    info "  Connected to $ip"
  done

  # Create brick directories on all nodes first
  doing "Creating brick directories on all nodes..."
  for ip in "${NODE_IPS[@]}"; do
    sshRun "$VM_USER" "$ip" "sudo mkdir -p $BRICK && sudo mkdir -p $MOUNTPOINT"
  done

  # Probe peers for GlusterFS
  for peer in "${NODE_IPS[@]}"; do
    if ! sshRun "$VM_USER" "$MGR" "sudo gluster pool list | awk '{print \$2}' | grep -qx '$peer'"; then
      doing "Probing peer $peer"
      sshRun "$VM_USER" "$MGR" "sudo gluster peer probe $peer"
    else
      info "$peer is already in pool"
    fi
  done

  sleep 2

  # Create and start GlusterFS volume
  BRICKS="$MGR:$BRICK $ND1:$BRICK $ND2:$BRICK"
  if ! sshRun "$VM_USER" "$MGR" "sudo gluster volume info $VOL >/dev/null 2>&1"; then
    doing "Creating volume $VOL"
    sshRun "$VM_USER" "$MGR" "sudo gluster volume create $VOL replica 3 $BRICKS force"
  else
    info "Volume $VOL exists"
  fi

  if ! sshRun "$VM_USER" "$MGR" "sudo gluster volume status $VOL >/dev/null 2>&1"; then
    doing "Starting volume $VOL"
    sshRun "$VM_USER" "$MGR" "sudo gluster volume start $VOL"
  fi

  sleep 2

  # Set recommended GlusterFS options
  for opt in \
    "cluster.quorum-type auto" \
    "cluster.self-heal-daemon on" \
    "cluster.data-self-heal on" \
    "cluster.metadata-self-heal on" \
    "cluster.entry-self-heal on" \
    "performance.client-io-threads on" \
    "network.ping-timeout 10"
  do
    sshRun "$VM_USER" "$MGR" "sudo gluster volume set $VOL $opt || true"
  done

  sleep 2

  # Mount with fstab on all nodes
  for ip in "${NODE_IPS[@]}"; do
    doing "Mounting GlusterFS on $ip"
    sshRun "$VM_USER" "$ip" "sudo mkdir -p '$MOUNTPOINT'"
    # Add fstab entry if not present
    sshRun "$VM_USER" "$ip" "grep -q ':/${VOL}' /etc/fstab || echo 'localhost:/${VOL} ${MOUNTPOINT} glusterfs defaults,_netdev 0 0' | sudo tee -a /etc/fstab >/dev/null"
    # Mount if not already mounted
    sshRun "$VM_USER" "$ip" "mountpoint -q '$MOUNTPOINT' || sudo mount -t glusterfs localhost:/${VOL} ${MOUNTPOINT}"
  done

  sleep 2

  # Restart Nomad now that GlusterFS is mounted
  doing "Starting Nomad on all nodes..."
  for ip in "${NODE_IPS[@]}"; do
    sshRun "$VM_USER" "$ip" "sudo systemctl restart nomad"
  done

  sleep 2

  # Verify GlusterFS
  sshRun "$VM_USER" "$MGR" "sudo gluster volume info $VOL"
  sshRun "$VM_USER" "$MGR" "sudo gluster volume status $VOL"
  sshRun "$VM_USER" "$MGR" "sudo gluster volume heal $VOL info || true"

  success "GlusterFS '$VOL' up on: ${NODE_IPS[*]}"
  info "Mounted at ${MOUNTPOINT} on each node."

  # Wait for Nomad cluster to form (servers auto-join via cloud-init config)
  doing "Waiting for Nomad cluster to form..."
  sleep 10

  local retries=30
  local count=0
  while [ $count -lt $retries ]; do
    SERVER_COUNT=$(sshRun "$VM_USER" "$MGR" "nomad server members 2>/dev/null | grep -c alive || echo 0")
    if [ "$SERVER_COUNT" -eq 3 ]; then
      success "Nomad cluster formed with 3 server members"
      break
    fi
    ((count++))
    info "Waiting for Nomad servers to join... ($count/$retries) - $SERVER_COUNT/3 servers alive"
    sleep 5
  done

  if [ $count -eq $retries ]; then
    warn "Nomad cluster may not be fully formed. Please check manually."
  fi

  # Verify Nomad cluster health
  doing "Verifying Nomad cluster health"
  sshRun "$VM_USER" "$MGR" "nomad server members"
  sshRun "$VM_USER" "$MGR" "nomad node status"

  success "Nomad cluster setup complete!"
  info "Access Nomad UI at: http://${MGR}:4646"
}

function deployTraefikOnly() {
  cat <<EOF

############################################################################
Traefik Load Balancer Deployment

Deploying Traefik as a Nomad system job for load balancing and service discovery.
Assumes Nomad cluster is already running.
#############################################################################

EOF

  # Deploy Traefik using the generic Nomad job deployer
  if ! deployNomadJob "traefik" "nomad/jobs/traefik.nomad.hcl" "/srv/gluster/nomad-data/traefik"; then
    return 1
  fi

  # Get Nomad IP for display
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  echo
  info "Dashboard: http://$NOMAD_IP:8081/dashboard/"
  info "HTTP:      http://$NOMAD_IP:80"
  info "HTTPS:     https://$NOMAD_IP:443"

  # Update DNS records for traefik
  updateDNSRecords
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
    # Create proxmox alias pointing to ALL nodes for round-robin DNS
    NODE_RECORDS_ALIAS_JSON="$(jq -c --arg suffix "$DNS_POSTFIX" \
      '[.nodes[] | "\(.ip) proxmox proxmox.\($suffix)"]' "$CLUSTER_INFO_FILE")"

    echo "  Proxmox nodes:"
    jq -r '.nodes[] | "    - \(.name).\($suffix) -> \(.ip)"' --arg suffix "$DNS_POSTFIX" "$CLUSTER_INFO_FILE"
    echo "  Round-robin alias:"
    jq -r '.nodes[] | "    - proxmox.\($suffix) -> \(.ip)"' --arg suffix "$DNS_POSTFIX" "$CLUSTER_INFO_FILE"
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
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$DNS_IP" "
    pihole-FTL --config dns.hosts '$ALL_DNS_RECORDS_JSON' &&
    pihole-FTL --config dns.cnameRecords '[\"ca.$DNS_POSTFIX,step-ca.$DNS_POSTFIX\"]'
  " && success "Pi-hole DNS records updated" || error "Failed to update Pi-hole"

  # Trigger Nebula-Sync to propagate changes
  doing "Triggering Nebula-Sync to propagate to replicas..."
  if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes "$REMOTE_USER@$DNS_IP" \
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
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
        "sed -i '/^nameserver/d' /etc/resolv.conf && echo 'nameserver $DNS_IP' >> /etc/resolv.conf && echo 'nameserver 1.1.1.1' >> /etc/resolv.conf"
      echo "  - $node: DNS set to $DNS_IP"
    done
    success "Proxmox DNS settings updated"
  fi
}

function updateRootCertificates() {
  # Load configuration from cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    PROXMOX_HOST=$(jq -r '.nodes[0].ip // ""' "$CLUSTER_INFO_FILE")
  fi

  # Fallback prompts only if not in cluster-info.json
  if [ -z "${DNS_POSTFIX}" ]; then
    read -rp "Enter your DNS suffix: " DNS_POSTFIX
  fi

  if [ -s hosts.json ]; then
    CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  fi
  if [[ -z "$CA_IP" || "$CA_IP" == "null" ]]; then
    read -rp "Enter CA IP address: " CA_IP
  fi
  if [[ -z "$DNS_IP" || "$DNS_IP" == "null" ]]; then
    read -rp "Enter primary DNS server IP (dns-01): " DNS_IP
  fi

  local CA_URL="https://$CA_IP/roots.pem"
  local ACME_DIR="https://ca.${DNS_POSTFIX}/acme/acme/directory"

  doing "Reading node list from ${PROXMOX_HOST}:/etc/pve/.members"
  local MEMBERS_JSON
  MEMBERS_JSON="$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" 'cat /etc/pve/.members')"
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
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$name" "
      # Remove any existing proxmox-lab CA certificates first
      rm -f /usr/local/share/ca-certificates/proxmox-lab*.crt
      rm -f /etc/ssl/certs/proxmox-lab*.pem
    "
    scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR proxmox-lab-root-ca.crt \
      "$REMOTE_USER@$name:/usr/local/share/ca-certificates/proxmox-lab-root-ca.crt"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$name" "
      set -e
      update-ca-certificates --fresh
      systemctl reload pveproxy || systemctl restart pveproxy
    "
  done

  # Configure all nodes to use Pi-hole as DNS (required for ACME hostname resolution)
  doing "Configuring DNS on all nodes to use Pi-hole ($DNS_IP)"
  for node_ip in "${NODE_IPS[@]}"; do
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$node_ip" \
      "echo 'nameserver ${DNS_IP}' > /etc/resolv.conf && echo 'search ${DNS_POSTFIX}' >> /etc/resolv.conf" \
      || warn "Failed to configure DNS on $node_ip"
  done

  doing "Registering ACME account 'default' against Step CA directory"
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" "
    # Deactivate existing account if present (needed after CA regeneration)
    pvenode acme account deactivate default 2>/dev/null || true
    rm -f /etc/pve/priv/acme/default 2>/dev/null || true
    pvenode acme account register default admin@example.com --directory '$ACME_DIR'
  "

  doing "Ordering/renewing certs per node (with proxmox.${DNS_POSTFIX} SAN)"
  local pmfqdn="proxmox.${DNS_POSTFIX}"

  # Build base DNS records (without proxmox entries) from hosts.json and cluster-info.json
  # This avoids reading from pihole-FTL which returns non-JSON format
  local BASE_RECORDS="[]"

  # Add node records from cluster-info.json (pve01, pve02, pve03 - but not proxmox alias)
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    BASE_RECORDS=$(jq -c --arg suffix "$DNS_POSTFIX" \
      '[.nodes[] | "\(.ip) \(.name) \(.name).\($suffix)"]' "$CLUSTER_INFO_FILE")
  fi

  # Add service records from hosts.json
  if [ -s hosts.json ]; then
    local SERVICE_RECORDS
    SERVICE_RECORDS=$(jq -c --arg suffix "$DNS_POSTFIX" \
      '(.external // []) | map("\(.ip | split("/")[0]) \(.hostname) \(.hostname).\($suffix)")' hosts.json)
    # Add dns alias
    local DNS_ALIAS
    DNS_ALIAS=$(jq -c -n --arg ip "$DNS_IP" --arg suffix "$DNS_POSTFIX" '["\($ip) dns dns.\($suffix)"]')
    BASE_RECORDS=$(jq -c -n --argjson base "$BASE_RECORDS" --argjson svc "$SERVICE_RECORDS" --argjson dns "$DNS_ALIAS" \
      '$base + $svc + $dns | unique')
  fi

  # Build array of all node IPs for round-robin restore later
  local ALL_NODE_IPS=()
  while IFS= read -r node_ip; do
    [[ -n "$node_ip" ]] && ALL_NODE_IPS+=("$node_ip")
  done < <(jq -r '.nodelist | to_entries[] | .value.ip' <<<"$MEMBERS_JSON")

  exec 3< <(jq -r '.nodelist | to_entries[] | "\(.key)\t\(.value.ip)"' <<<"$MEMBERS_JSON")
  while IFS=$'\t' read -r name ip <&3; do
    [[ -z "$name" || -z "$ip" ]] && continue
    fqdn="${name}.${DNS_POSTFIX}"
    # Include IP address as SAN so accessing by IP doesn't show cert warnings
    acme_map="account=default,domains=${fqdn};${pmfqdn};${ip}"

    info "  - $name ($ip) -> $fqdn, ${pmfqdn}, ${ip}"

    # Temporarily point proxmox.DOMAIN only to this node for ACME HTTP-01 validation
    # Build complete record set with only this node's proxmox entry
    doing "    Temporarily setting DNS: ${pmfqdn} -> ${ip}"
    local TEMP_RECORDS
    TEMP_RECORDS=$(jq -c -n --argjson base "$BASE_RECORDS" --arg ip "$ip" --arg pm "$pmfqdn" \
      '$base + ["\($ip) proxmox \($pm)"]')

    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$DNS_IP" \
      "pihole-FTL --config dns.hosts '$TEMP_RECORDS'" || { warn "Failed to update DNS for $name"; continue; }

    # Brief pause for DNS propagation
    sleep 2

    # Order certificate
    doing "    Ordering certificate for $name"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" "
      set -e
      # Clear any stale ACME config before setting new domains
      pvenode config set --delete acme 2>/dev/null || true
      pvenode config set --acme \"$acme_map\"
      pvenode acme cert order -force
    " || { warn "SSH/ACME failed for $name ($ip)"; continue; }

    success "    Certificate issued for $name"
  done
  exec 3<&-

  # Restore round-robin DNS for proxmox.DOMAIN (all nodes)
  doing "Restoring round-robin DNS for ${pmfqdn}"
  local ROUNDROBIN_ENTRIES="[]"
  for node_ip in "${ALL_NODE_IPS[@]}"; do
    ROUNDROBIN_ENTRIES=$(jq -c -n --argjson arr "$ROUNDROBIN_ENTRIES" --arg ip "$node_ip" --arg pm "$pmfqdn" \
      '$arr + ["\($ip) proxmox \($pm)"]')
  done

  local FINAL_RECORDS
  FINAL_RECORDS=$(jq -c -n --argjson base "$BASE_RECORDS" --argjson rr "$ROUNDROBIN_ENTRIES" '$base + $rr')

  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$DNS_IP" \
    "pihole-FTL --config dns.hosts '$FINAL_RECORDS'" || warn "Failed to restore round-robin DNS"

  success "Root CA installed on all nodes; ACME certs issued; round-robin DNS restored."
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

# Complete purge - reset nodes to pre-install state
function purgeEntireDeployment() {
  cat <<EOF

############################################################################
Complete Deployment Purge

This will COMPLETELY remove all lab infrastructure and reset Proxmox nodes
to their pre-install state:

  - All VMs and LXC containers
  - Cloud-init snippets
  - ACME certificates
  - Step-CA root certificate from trust store
  - DNS configuration
  - Hashicorp API user
  - SSH keys (removed last)
  - Local configuration files

This action cannot be undone.
#############################################################################

EOF

  read -rp "$(question "Are you sure? Type 'PURGE' to confirm: ")" CONFIRM
  if [[ "$CONFIRM" != "PURGE" ]]; then
    info "Purge cancelled"
    return 0
  fi

  # Load cluster info for multi-node cleanup
  if ! ensureClusterContext; then
    warn "No cluster info found. Attempting to proceed with single node..."
    if [ -z "$PROXMOX_HOST" ]; then
      read -rp "$(question "Enter Proxmox host IP: ")" PROXMOX_HOST
    fi
    CLUSTER_NODES=("$PROXMOX_HOST")
    CLUSTER_NODE_IPS=("$PROXMOX_HOST")
  fi

  echo
  warn "Starting complete deployment purge..."
  echo

  # Step 1: Purge all VMs and LXC containers
  doing "Step 1/8: Purging all VMs and LXC containers..."
  purgeClusterResources --auto || true

  # Step 2: Remove cloud-init snippets
  doing "Step 2/8: Removing cloud-init snippets..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Cleaning snippets on $node..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
      "rm -rf /var/lib/vz/snippets/*-user-data.yml 2>/dev/null" || true
  done
  success "Cloud-init snippets removed"

  # Step 3: Remove ACME certificates
  doing "Step 3/8: Removing ACME certificates..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing ACME config on $node..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
      "pvenode config set --delete acme 2>/dev/null; pvenode acme account deactivate 2>/dev/null" || true
  done
  success "ACME certificates removed"

  # Step 4: Remove step-ca root cert from trust store
  doing "Step 4/8: Removing step-ca root certificate from trust store..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing CA cert on $node..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
      "rm -f /usr/local/share/ca-certificates/step-ca-root.crt 2>/dev/null; update-ca-certificates 2>/dev/null" || true
  done
  success "Step-CA root certificate removed"

  # Step 5: Reset node DNS configuration
  doing "Step 5/8: Resetting DNS configuration..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Resetting DNS on $node..."
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
      "sed -i 's/^nameserver .*/nameserver 1.1.1.1/' /etc/resolv.conf 2>/dev/null" || true
  done
  success "DNS configuration reset"

  # Step 6: Remove hashicorp API user
  doing "Step 6/8: Removing hashicorp API user..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@${CLUSTER_NODE_IPS[0]}" \
    "pveum user delete hashicorp@pam 2>/dev/null; pveum token delete hashicorp@pam hashicorp-token 2>/dev/null" || true
  success "Hashicorp API user removed"

  # Step 7: Clean local files
  doing "Step 7/8: Cleaning local configuration files..."
  rm -f hosts.json 2>/dev/null || true
  # Remove auto-generated sections from terraform.tfvars (keep manual config)
  if [ -f "terraform/terraform.tfvars" ]; then
    sed -i.bak '/# Proxmox cluster node IPs (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    sed -i.bak '/# DNS cluster nodes - Main cluster (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    sed -i.bak '/# DNS cluster nodes - Labnet SDN cluster (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    rm -f terraform/terraform.tfvars.bak 2>/dev/null || true
  fi
  # Remove storage config from cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local tmp=$(mktemp)
    jq 'del(.storage)' "$CLUSTER_INFO_FILE" > "$tmp" && mv "$tmp" "$CLUSTER_INFO_FILE"
  fi
  # Clean packer storage settings
  if [ -f "packer/packer.auto.pkrvars.hcl" ]; then
    grep -v "^template_storage" packer/packer.auto.pkrvars.hcl > packer/packer.auto.pkrvars.hcl.tmp 2>/dev/null || true
    mv packer/packer.auto.pkrvars.hcl.tmp packer/packer.auto.pkrvars.hcl 2>/dev/null || true
  fi
  # Clean terraform state
  docker compose run --rm -T terraform state list 2>/dev/null | while read -r resource; do
    docker compose run --rm -T terraform state rm "$resource" 2>/dev/null || true
  done
  success "Local files cleaned"

  # Step 8: Remove SSH keys (LAST - we need SSH for all previous steps!)
  doing "Step 8/8: Removing SSH keys from nodes..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing SSH key on $node..."
    # Get the public key content to remove from authorized_keys
    if [ -f "${KEY_PATH}.pub" ]; then
      local pubkey
      pubkey=$(cat "${KEY_PATH}.pub")
      ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$ip" \
        "grep -v '$pubkey' /root/.ssh/authorized_keys > /tmp/ak_tmp && mv /tmp/ak_tmp /root/.ssh/authorized_keys" 2>/dev/null || true
    fi
  done
  success "SSH keys removed from nodes"

  echo
  success "Complete deployment purge finished!"
  warn "You may want to delete the local crypto/ directory if you no longer need the SSH keys."
  warn "You may also want to delete cluster-info.json to start fresh."
}

function destroyLab() {
  warn "This will DESTROY all lab infrastructure and remove all configurations."
  warn "This action cannot be undone."
  echo
  read -rp "$(question "Are you sure? Type 'destroy' to confirm: ")" CONFIRM
  if [[ "$CONFIRM" != "destroy" ]]; then
    info "Destruction cancelled"
    return 0
  fi

  checkProxmox

  # Load cluster info for multi-node cleanup
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    loadClusterInfo 2>/dev/null || true
  fi

  # 1. Terraform destroy
  doing "Destroying Terraform infrastructure..."
  if docker compose run --rm -it terraform destroy; then
    success "Terraform destruction complete"
  else
    warn "Terraform destroy had errors - continuing with cleanup"
  fi

  # 2. Clean ALL cluster nodes (not just primary)
  doing "Cleaning Proxmox nodes..."
  if [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
    for i in "${!CLUSTER_NODE_IPS[@]}"; do
      local node_ip="${CLUSTER_NODE_IPS[$i]}"
      local node_name="${CLUSTER_NODES[$i]}"

      info "  Cleaning $node_name ($node_ip)..."

      # Run proxmox/setup.sh destroy on each node
      sshRun $REMOTE_USER "$node_ip" 'bash /root/setup.sh destroy 2>/dev/null || true'

      # Remove CA certificates
      sshRun $REMOTE_USER "$node_ip" 'rm -f /usr/local/share/ca-certificates/proxmox-lab*.crt && update-ca-certificates 2>/dev/null || true'

      # Reset DNS
      sshRun $REMOTE_USER "$node_ip" 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'

      # Deactivate ACME account (only needs to run once - cluster-wide, done on primary)
      if [ "$i" -eq 0 ]; then
        sshRun $REMOTE_USER "$node_ip" 'pvenode acme account deactivate default 2>/dev/null || true'
        sshRun $REMOTE_USER "$node_ip" 'rm -f /etc/pve/priv/acme/default 2>/dev/null || true'
      fi
    done
  else
    # Fallback to primary host only if cluster info not available
    info "  Cleaning $PROXMOX_HOST (primary)..."
    sshRun $REMOTE_USER $PROXMOX_HOST 'bash /root/setup.sh destroy 2>/dev/null || true'
    sshRun $REMOTE_USER $PROXMOX_HOST 'rm -f /usr/local/share/ca-certificates/proxmox-lab*.crt && update-ca-certificates 2>/dev/null || true'
    sshRun $REMOTE_USER $PROXMOX_HOST 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
    sshRun $REMOTE_USER $PROXMOX_HOST 'pvenode acme account deactivate default 2>/dev/null || true'
    sshRun $REMOTE_USER $PROXMOX_HOST 'rm -f /etc/pve/priv/acme/default 2>/dev/null || true'
  fi

  # 3. Clean local files
  doing "Cleaning local files..."
  rm -rf packer/packer-outputs 2>/dev/null || true
  rm -rf terraform/lxc-step-ca/step-ca 2>/dev/null || true
  rm -rf terraform/vm-docker-swarm/rendered 2>/dev/null || true
  rm -rf terraform/vm-kasm/rendered 2>/dev/null || true
  rm -f hosts.json 2>/dev/null || true
  rm -f cluster-info.json 2>/dev/null || true
  rm -f proxmox-lab-root-ca.crt 2>/dev/null || true
  rm -f kasm_nginx.crt 2>/dev/null || true
  info "  Standard files cleaned"

  # Optionally clean terraform state (with confirmation)
  if [ -f "terraform/terraform.tfstate" ] || [ -d "terraform/.terraform" ]; then
    echo
    read -rp "$(question "Remove Terraform state files? This cannot be undone. [y/N]: ")" REMOVE_STATE
    if [[ "$REMOVE_STATE" =~ ^[Yy]$ ]]; then
      rm -f terraform/terraform.tfstate 2>/dev/null || true
      rm -f terraform/terraform.tfstate.backup 2>/dev/null || true
      rm -rf terraform/.terraform 2>/dev/null || true
      rm -f terraform/.terraform.lock.hcl 2>/dev/null || true
      info "  Terraform state cleaned"
    fi
  fi

  # Optionally clean SSH keys (with confirmation)
  if [ -d "crypto" ]; then
    echo
    read -rp "$(question "Remove SSH keys? You'll need to regenerate them. [y/N]: ")" REMOVE_KEYS
    if [[ "$REMOVE_KEYS" =~ ^[Yy]$ ]]; then
      rm -rf crypto/ 2>/dev/null || true
      info "  SSH keys cleaned"
    fi
  fi

  # 4. Verify cleanup
  echo
  doing "Verifying cleanup..."
  local HAS_ORPHANS=false

  if [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
    local PRIMARY_IP="${CLUSTER_NODE_IPS[0]}"

    # Check for orphaned VMs
    local ORPHANED_VMS
    ORPHANED_VMS=$(sshRun $REMOTE_USER "$PRIMARY_IP" 'qm list 2>/dev/null | grep -E "(docker|kasm|dns|step-ca)" || true')
    if [ -n "$ORPHANED_VMS" ]; then
      warn "Orphaned VMs detected:"
      echo "$ORPHANED_VMS"
      HAS_ORPHANS=true
    fi

    # Check for orphaned LXCs
    local ORPHANED_LXCS
    ORPHANED_LXCS=$(sshRun $REMOTE_USER "$PRIMARY_IP" 'pct list 2>/dev/null | grep -E "(dns|step-ca)" || true')
    if [ -n "$ORPHANED_LXCS" ]; then
      warn "Orphaned LXC containers detected:"
      echo "$ORPHANED_LXCS"
      HAS_ORPHANS=true
    fi
  fi

  if [ "$HAS_ORPHANS" = false ]; then
    info "  No orphaned resources detected"
  fi

  echo
  success "Lab destruction complete"
}

function runProxmoxSetupOnAll() {
  doing "Running Proxmox setup on all cluster nodes..."

  # Build config JSON from cluster-info.json (includes storage and bridge)
  local CONFIG
  CONFIG=$(cat "$CLUSTER_INFO_FILE")

  # Cluster-wide setup (run once on primary)
  local PRIMARY_IP="${CLUSTER_NODE_IPS[0]}"
  doing "Running cluster-wide Proxmox setup on ${CLUSTER_NODES[0]} ($PRIMARY_IP)..."

  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR proxmox/setup.sh "root@${PRIMARY_IP}:/tmp/proxmox-setup.sh"
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "root@${PRIMARY_IP}" \
    "chmod +x /tmp/proxmox-setup.sh && /tmp/proxmox-setup.sh cluster-init '$CONFIG'"

  # Per-node setup (run on each node) - pass config for storage/bridge settings
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    doing "Running node setup on $node ($ip)..."
    scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR proxmox/setup.sh "root@${ip}:/tmp/proxmox-setup.sh"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "root@${ip}" \
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

  # Update vm_storage (for VM disks - should match template storage)
  if grep -q "^vm_storage" "$TFVARS_FILE"; then
    sed_inplace "s|^vm_storage = .*|vm_storage = \"$STORAGE_VAL\"|" "$TFVARS_FILE"
  else
    echo "" >> "$TFVARS_FILE"
    echo "# VM storage (should match template storage for fast cloning)" >> "$TFVARS_FILE"
    echo "vm_storage = \"$STORAGE_VAL\"" >> "$TFVARS_FILE"
  fi
  info "  vm_storage = \"$STORAGE_VAL\""

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
     --arg storage_type "${TEMPLATE_STORAGE_TYPE:-lvm}" \
     --argjson shared "$USE_SHARED_STORAGE" \
     --arg bridge "$NETWORK_BRIDGE" \
     '. + {
       storage: { selected: $storage, type: $storage_type, is_shared: $shared },
       network: (.network + { selected_bridge: $bridge })
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  # Update terraform.tfvars from cluster-info.json
  updateTerraformFromClusterInfo

  # Run Proxmox setup on all nodes
  runProxmoxSetupOnAll

  # Optional post-install script
  proxmoxPostInstall

  # Deploy services (LXC, Packer, VMs)
  deployAllServices

  # Setup Nomad cluster
  setupNomadCluster
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
     --arg storage_type "${TEMPLATE_STORAGE_TYPE:-lvm}" \
     --argjson shared "$USE_SHARED_STORAGE" \
     --arg bridge "$NETWORK_BRIDGE" \
     '. + {
       storage: { selected: $storage, type: $storage_type, is_shared: $shared },
       network: (.network + { selected_bridge: $bridge })
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  # Update terraform.tfvars from cluster-info.json
  updateTerraformFromClusterInfo

  # Run Proxmox setup on all nodes
  runProxmoxSetupOnAll

  # Optional post-install script
  proxmoxPostInstall

  # Deploy services
  deployAllServices

  # Setup Nomad cluster
  setupNomadCluster
}

function manualRollback() {
  cat <<EOF

#############################################################################
Rollback Service Deployment (Terraform)

  1) Rollback LXC containers (DNS, CA)
  2) Rollback VMs (Nomad, Kasm)
  0) Back to main menu
#############################################################################

EOF

  read -rp "$(question "Select option [0-2]: ")" OPTION
  case $OPTION in
    0)
      SKIP_PAUSE=true
      return 0
      ;;
    1)
      echo
      warn "This will DESTROY the following LXC containers:"
      echo "  - DNS cluster (dns-01, dns-02, dns-03)"
      echo "  - Labnet DNS cluster (labnet-dns-01, labnet-dns-02)"
      echo "  - Step-CA (Certificate Authority)"
      echo
      read -rp "$(question "Are you sure you want to proceed? [y/N]: ")" CONFIRM
      if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Operation cancelled"
        return 0
      fi

      doing "Destroying LXC containers (DNS, step-ca)..."
      docker compose run --rm terraform destroy \
        -target=module.dns-main \
        -target=module.dns-labnet \
        -target=module.step-ca \
        -auto-approve 2>/dev/null || true
      success "LXC containers destroyed"
      ;;
    2)
      echo
      warn "This will DESTROY the following VMs:"
      echo "  - Nomad cluster (nomad01, nomad02, nomad03)"
      echo "  - Kasm Workspaces (kasm01)"
      echo
      read -rp "$(question "Are you sure you want to proceed? [y/N]: ")" CONFIRM
      if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Operation cancelled"
        return 0
      fi

      doing "Destroying VMs (Nomad, Kasm)..."
      docker compose run --rm terraform destroy \
        -target=module.nomad \
        -target=module.kasm \
        -auto-approve 2>/dev/null || true
      success "VMs destroyed"

      # Ask about Packer templates (only relevant when destroying VMs)
      echo
      read -rp "$(question "Also remove Packer templates (9001, 9002)? These take time to rebuild. [y/N]: ")" REMOVE_TEMPLATES
      if [[ "$REMOVE_TEMPLATES" =~ ^[Yy]$ ]]; then
        # Load cluster context if needed
        if [ -z "$PROXMOX_HOST" ]; then
          if [ -f "$CLUSTER_INFO_FILE" ]; then
            loadClusterInfo
            if [ -z "$PROXMOX_HOST" ] && [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
              PROXMOX_HOST="${CLUSTER_NODE_IPS[0]}"
            fi
          fi
        fi

        if [ -z "$PROXMOX_HOST" ]; then
          error "Cannot determine Proxmox host. Cluster info not found."
          return 1
        fi

        doing "Removing Packer templates from shared storage..."
        removeTemplateIfExists 9001 "docker-template"
        removeTemplateIfExists 9002 "nomad-template"
        success "Packer templates removed"
      else
        info "Packer templates preserved"
      fi
      ;;
    *)
      error "Invalid option"
      return 1
      ;;
  esac
}

function deployNomadOnly() {
  cat <<EOF

############################################################################
Nomad Cluster Deployment

This will build the Nomad Packer template and deploy Nomad VMs.
Assumes DNS and step-ca are already deployed.
#############################################################################

EOF

  # Load cluster context
  ensureClusterContext || return 1

  # Verify critical services are deployed
  ensureCriticalServices || return 1

  # Ensure shared storage is selected for clusters
  ensureSharedStorage || return 1

  # Verify hosts.json exists (needed for DNS records)
  if [ ! -f "hosts.json" ]; then
    warn "hosts.json not found, generating from Terraform..."
    docker compose run --rm -T terraform output -json host-records > hosts.json 2>&1 || true
  fi

  # ============================================
  # Build Nomad Packer Template Only
  # ============================================
  cat <<EOF

#############################################################################
Building Nomad Template

Building only the Nomad VM template with Packer.
#############################################################################
EOF
  pressAnyKey

  # Remove existing template if present
  removeTemplateIfExists 9002 "nomad-template"

  # Update Packer config with storage settings
  updatePackerStorageConfig

  doing "Building Nomad Packer template..."
  docker compose build packer >/dev/null 2>&1
  docker compose run --rm -it packer init .
  if ! docker compose run --rm -it packer build -only=ubuntu-nomad.proxmox-clone.ubuntu-nomad .; then
    error "Packer build failed for Nomad template"
    return 1
  fi
  success "Nomad template built"

  # Migrate template disk to shared storage for multi-node cloning
  migrateTemplateToSharedStorage 9002

  # ============================================
  # Deploy Nomad VMs
  # ============================================
  cat <<EOF

#############################################################################
Deploying Nomad VMs

Deploying Nomad cluster VMs from template.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying Nomad VMs..."
  docker compose run --rm -it terraform init
  if ! docker compose run --rm -it terraform apply -target=module.nomad; then
    error "Terraform apply failed for Nomad module"
    return 1
  fi

  success "Nomad VMs deployed"

  # Terraform outputs often have stale IPs for DHCP VMs
  # Query Proxmox directly via QEMU guest agent for actual IPs
  refreshHostsJsonFromProxmox "nomad" 905 907

  # Update DNS records with actual IPs
  updateDNSRecords

  # ============================================
  # Configure Nomad Cluster
  # ============================================
  cat <<EOF

#############################################################################
Configuring Nomad Cluster

Setting up GlusterFS and verifying Nomad cluster formation.
#############################################################################
EOF
  pressAnyKey

  setupNomadCluster

  success "Nomad cluster deployment complete!"
}

function deployKasmOnly() {
  cat <<EOF

############################################################################
Kasm Workspaces Deployment (Skip LXC)

This will deploy Kasm Workspaces VM from the docker-template.
Assumes DNS and step-ca are already deployed.
#############################################################################

EOF

  # Load cluster context
  ensureClusterContext || return 1

  # Verify critical services are deployed
  ensureCriticalServices || return 1

  # Ensure shared storage is selected for clusters
  ensureSharedStorage || return 1

  # Verify hosts.json exists (needed for DNS records)
  if [ ! -f "hosts.json" ]; then
    warn "hosts.json not found, generating from Terraform..."
    docker compose run --rm -T terraform output -json host-records > hosts.json 2>&1 || true
  fi

  # Check if docker-template exists, offer to build if missing
  if ! ensureTemplate 9001 "docker-template"; then
    echo
    warn "docker-template (VM 9001) is required but not found."
    read -rp "$(question "Build docker-template now? [Y/n]: ")" BUILD_TEMPLATE
    if [[ "$BUILD_TEMPLATE" =~ ^[Nn]$ ]]; then
      info "Cannot deploy Kasm without docker-template."
      return 1
    fi

    # Update Packer config with storage settings
    updatePackerStorageConfig

    # Build docker template only
    doing "Building docker-template with Packer..."
    docker compose build packer >/dev/null 2>&1
    docker compose run --rm -it packer init .
    if ! docker compose run --rm -it packer build -only=ubuntu-docker.proxmox-clone.ubuntu-docker .; then
      error "Packer build failed for docker-template"
      return 1
    fi
    success "docker-template built"

    # Migrate to shared storage if needed
    migrateTemplateToSharedStorage 9001
  fi

  # ============================================
  # Deploy Kasm VM
  # ============================================
  cat <<EOF

#############################################################################
Deploying Kasm Workspaces

Deploying Kasm VM from docker-template.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying Kasm VM..."
  docker compose run --rm -it terraform init
  if ! docker compose run --rm -it terraform apply -target=module.kasm; then
    error "Terraform apply failed for Kasm module"
    return 1
  fi

  success "Kasm VM deployed"

  # Terraform outputs often have stale IPs for DHCP VMs
  # Query Proxmox directly via QEMU guest agent for actual IPs
  refreshHostsJsonFromProxmox "kasm" 930 930

  # Update DNS records with actual IPs
  updateDNSRecords

  # Get Kasm IP
  KASM_IP=$(jq -r '.external[] | select(.hostname == "kasm01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  cat <<EOF

#############################################################################
Kasm Deployment Complete!

Kasm Workspaces has been deployed. Access the admin console at:
  https://kasm.${DNS_POSTFIX}/

Or directly at: https://${KASM_IP}/

Default admin credentials are set via kasm_admin_password in terraform.tfvars.
#############################################################################
EOF

  success "Kasm deployment complete!"
}

function showMenu() {
  echo
  echo "=========================================="
  echo "  Proxmox Lab - Main Menu"
  echo "=========================================="
  echo
  echo "  1) New installation"
  echo "  2) New installation - skip SSH key gen"
  echo "  3) Deploy all services (DNS, CA, Nomad, Kasm)"
  echo "  4) Deploy critical services only (DNS, CA)"
  echo "  5) Deploy Nomad only"
  echo "  6) Deploy Kasm only"
  echo "  7) Deploy Traefik load balancer"
  echo "  8) Build DNS records"
  echo "  9) Regenerate CA"
  echo " 10) Update Proxmox root certificates"
  echo " 11) Rollback service deployment (Terraform)"
  echo " 12) Purge service deployment (Emergency)"
  echo " 13) Purge entire deployment"
  echo "  0) Exit"
  echo
}

header

while true; do
  showMenu
  read -rp "$(question "Select an option [0-13]: ")" choice

  case $choice in
    1) runEverything;;
    2) runEverythingButSSH;;
    3) deployAllServices;;
    4) deployCriticalServicesOnly;;
    5) deployNomadOnly;;
    6) deployKasmOnly;;
    7) deployTraefikOnly;;
    8) updateDNSRecords;;
    9) regenerateCA;;
    10) updateRootCertificates;;
    11) manualRollback;;
    12) purgeClusterResources;;
    13) purgeEntireDeployment;;
    0|q|Q) warn "Exiting..."; break;;
    *) error "Invalid option: $choice";;
  esac

  # Skip pause if returning from submenu
  if [ "${SKIP_PAUSE:-false}" = "true" ]; then
    SKIP_PAUSE=false
  else
    echo
    read -rp "Press Enter to continue..."
  fi
done
