#!/usr/bin/env bash

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
    done < <(sshRun "$REMOTE_USER" "$ip" "pvesh get /nodes/$node/network --output-format json 2>/dev/null" | \
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
    info "Service Network Bridge Selection"
    info "This bridge is where VMs and containers will connect (DNS, Nomad, step-ca, etc.)"
    info "This is NOT the labnet SDN egress bridge - that is configured separately."
    echo
    info "Available bridges (present on all nodes):"
    echo

    # Get IPs for each bridge from first node to help identify them
    for i in "${!ALL_BRIDGES[@]}"; do
      local bridge_ip=""
      bridge_ip=$(sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" \
        "ip -4 addr show ${ALL_BRIDGES[$i]} 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1" 2>/dev/null || echo "")
      if [ -n "$bridge_ip" ]; then
        echo "    $((i + 1)). ${ALL_BRIDGES[$i]} ($bridge_ip)"
      else
        echo "    $((i + 1)). ${ALL_BRIDGES[$i]} (no IP)"
      fi
    done
    echo

    read -rp "$(question "Select service network bridge [1]: ")" BRIDGE_CHOICE
    BRIDGE_CHOICE=${BRIDGE_CHOICE:-1}

    if [[ "$BRIDGE_CHOICE" =~ ^[0-9]+$ ]] && [ "$BRIDGE_CHOICE" -ge 1 ] && [ "$BRIDGE_CHOICE" -le "${#ALL_BRIDGES[@]}" ]; then
      NETWORK_BRIDGE="${ALL_BRIDGES[$((BRIDGE_CHOICE - 1))]}"
    else
      warn "Invalid selection, using ${ALL_BRIDGES[0]}"
      NETWORK_BRIDGE="${ALL_BRIDGES[0]}"
    fi
  fi

  export NETWORK_BRIDGE
  success "Using network bridge: $NETWORK_BRIDGE"
}