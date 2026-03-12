#!/usr/bin/env bash

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

    echo
    info "Labnet Egress Configuration"
    info "(Which physical bridge should labnet traffic use for internet access?)"
    info "Use the external bridge ($BRIDGE_VAL) unless you have a dedicated routing interface."
    echo

    read -rp "$(question "Labnet egress bridge [$BRIDGE_VAL]: ")" INT_EGRESS_BRIDGE
    INT_EGRESS_BRIDGE=${INT_EGRESS_BRIDGE:-$BRIDGE_VAL}

    # Try to get the IP of the egress bridge from Proxmox
    local DETECTED_EGRESS_IP=""
    if [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
      # Query the first node to get the IP address of the egress bridge
      DETECTED_EGRESS_IP=$(sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" \
        "ip -4 addr show $INT_EGRESS_BRIDGE 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1" 2>/dev/null || echo "")
    fi

    if [ -n "$DETECTED_EGRESS_IP" ]; then
      info "Detected IP for $INT_EGRESS_BRIDGE: $DETECTED_EGRESS_IP"
      read -rp "$(question "Labnet egress source IP [$DETECTED_EGRESS_IP]: ")" INT_EGRESS_IP
      INT_EGRESS_IP=${INT_EGRESS_IP:-$DETECTED_EGRESS_IP}
    else
      warn "Could not detect IP for $INT_EGRESS_BRIDGE - please enter manually"
      read -rp "$(question "Labnet egress source IP: ")" INT_EGRESS_IP
      while [ -z "$INT_EGRESS_IP" ]; do
        warn "Egress IP is required for SNAT"
        read -rp "$(question "Labnet egress source IP: ")" INT_EGRESS_IP
      done
    fi
  else
    CREATE_SDN=false
    INT_CIDR=""
    INT_GATEWAY=""
    INT_EGRESS_BRIDGE=""
    INT_EGRESS_IP=""
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
  Egress Bridge:     $INT_EGRESS_BRIDGE
  Egress IP (SNAT):  $INT_EGRESS_IP
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
     --arg int_egress_bridge "$INT_EGRESS_BRIDGE" \
     --arg int_egress_ip "$INT_EGRESS_IP" \
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
           gateway: $int_gw,
           egress_bridge: $int_egress_bridge,
           egress_ip: $int_egress_ip
         }
       },
       dns_postfix: $dns_postfix
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  success "Network configuration saved to $CLUSTER_INFO_FILE"
}