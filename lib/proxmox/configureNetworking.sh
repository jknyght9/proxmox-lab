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

  # DNS High Availability option
  echo
  info "DNS High Availability (keepalived)"
  info "(Optional: Provides a Virtual IP that fails over between Pi-hole nodes)"
  echo

  read -rp "$(question "Enable DNS HA with keepalived VIP? [y/N]: ")" ENABLE_HA_INPUT
  ENABLE_HA_INPUT=${ENABLE_HA_INPUT:-N}

  local ENABLE_HA=false
  local HA_VIP=""

  if [[ "$ENABLE_HA_INPUT" =~ ^[Yy]$ ]]; then
    ENABLE_HA=true
    # When HA enabled: VIP at .3, DNS nodes start at .4, services at .7
    local DEFAULT_HA_VIP="${CIDR_BASE}3"
    local DEFAULT_DNS_START="${CIDR_BASE}4"
    local DEFAULT_SVC_START="${CIDR_BASE}7"

    read -rp "$(question "DNS VIP address (failover endpoint) [$DEFAULT_HA_VIP]: ")" HA_VIP
    HA_VIP=${HA_VIP:-$DEFAULT_HA_VIP}

    info "Note: DNS containers will use privileged mode for keepalived"
  else
    # When HA disabled: DNS nodes start at .3, services at .6
    local DEFAULT_DNS_START="${CIDR_BASE}3"
    local DEFAULT_SVC_START="${CIDR_BASE}6"
  fi

  echo
  info "Service IP Allocation"
  info "(IP addresses for Pi-hole containers and other services)"
  if $ENABLE_HA; then
    info "  .3 = VIP (keepalived failover), .4+ = DNS nodes, .7+ = services"
  else
    info "  .3+ = DNS nodes, .6+ = services"
  fi
  echo

  read -rp "$(question "Pi-hole containers start IP [$DEFAULT_DNS_START]: ")" DNS_START_IP
  DNS_START_IP=${DNS_START_IP:-$DEFAULT_DNS_START}

  read -rp "$(question "Other services start IP (step-ca, kasm) [$DEFAULT_SVC_START]: ")" SVC_START_IP
  SVC_START_IP=${SVC_START_IP:-$DEFAULT_SVC_START}

  # Nomad Traefik High Availability option
  echo
  info "Nomad Traefik High Availability (keepalived)"
  info "(Optional: Provides a Virtual IP that fails over between Nomad nodes for Traefik)"
  echo

  read -rp "$(question "Enable Traefik HA with keepalived VIP? [y/N]: ")" ENABLE_TRAEFIK_HA_INPUT
  ENABLE_TRAEFIK_HA_INPUT=${ENABLE_TRAEFIK_HA_INPUT:-N}

  local ENABLE_TRAEFIK_HA=false
  local TRAEFIK_HA_VIP=""

  local TRAEFIK_HA_VRRP_ROUTER_ID=""
  local TRAEFIK_HA_VRRP_PASSWORD=""

  if [[ "$ENABLE_TRAEFIK_HA_INPUT" =~ ^[Yy]$ ]]; then
    ENABLE_TRAEFIK_HA=true
    # Suggest VIP in the services range (after step-ca)
    local DEFAULT_TRAEFIK_VIP="${CIDR_BASE}100"
    # Extract CIDR prefix from EXT_CIDR (e.g., /24 from 10.1.50.0/24)
    local CIDR_PREFIX
    CIDR_PREFIX=$(echo "$EXT_CIDR" | grep -oE '/[0-9]+$')

    read -rp "$(question "Traefik VIP address [$DEFAULT_TRAEFIK_VIP]: ")" TRAEFIK_HA_VIP
    TRAEFIK_HA_VIP=${TRAEFIK_HA_VIP:-$DEFAULT_TRAEFIK_VIP}
    # Append CIDR if not present
    [[ "$TRAEFIK_HA_VIP" != */* ]] && TRAEFIK_HA_VIP="${TRAEFIK_HA_VIP}${CIDR_PREFIX}"

    # Auto-generate VRRP router ID (53 for Traefik, avoiding 51/52 used by DNS HA)
    TRAEFIK_HA_VRRP_ROUTER_ID=53

    # Auto-generate random 8-character password
    TRAEFIK_HA_VRRP_PASSWORD=$(head -c 100 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)

    echo
    info "Auto-generated VRRP settings:"
    info "  Router ID: $TRAEFIK_HA_VRRP_ROUTER_ID"
    info "  Password:  $TRAEFIK_HA_VRRP_PASSWORD"
    info "Traefik will run on all Nomad nodes, VIP will float to active node"
  fi

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
    info "Labnet SDN Egress Bridge"
    info "This is the bridge labnet VMs use for OUTBOUND internet traffic (via SNAT)."
    info "This can be different from the service bridge selected earlier."
    echo

    # Detect available bridges from the primary node
    local AVAILABLE_BRIDGES=()
    local primary_node="${CLUSTER_NODES[0]}"
    if [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
      while IFS= read -r bridge; do
        [[ -n "$bridge" ]] && AVAILABLE_BRIDGES+=("$bridge")
      done < <(sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" \
        "pvesh get /nodes/$primary_node/network --output-format json 2>/dev/null" | \
        jq -r '.[] | select(.type == "bridge") | .iface' 2>/dev/null)
    fi

    # Select egress bridge
    if [ ${#AVAILABLE_BRIDGES[@]} -eq 0 ]; then
      warn "Could not detect bridges, using vmbr0"
      INT_EGRESS_BRIDGE="vmbr0"
    elif [ ${#AVAILABLE_BRIDGES[@]} -eq 1 ]; then
      INT_EGRESS_BRIDGE="${AVAILABLE_BRIDGES[0]}"
      info "Only one bridge available: $INT_EGRESS_BRIDGE"
    else
      info "Available bridges:"
      echo
      for i in "${!AVAILABLE_BRIDGES[@]}"; do
        # Get IP for this bridge to help user identify it
        local bridge_ip
        bridge_ip=$(sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" \
          "ip -4 addr show ${AVAILABLE_BRIDGES[$i]} 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1" 2>/dev/null || echo "no IP")
        echo "    $((i + 1)). ${AVAILABLE_BRIDGES[$i]} ($bridge_ip)"
      done
      echo

      read -rp "$(question "Select egress bridge [1]: ")" BRIDGE_CHOICE
      BRIDGE_CHOICE=${BRIDGE_CHOICE:-1}

      if [[ "$BRIDGE_CHOICE" =~ ^[0-9]+$ ]] && [ "$BRIDGE_CHOICE" -ge 1 ] && [ "$BRIDGE_CHOICE" -le "${#AVAILABLE_BRIDGES[@]}" ]; then
        INT_EGRESS_BRIDGE="${AVAILABLE_BRIDGES[$((BRIDGE_CHOICE - 1))]}"
      else
        warn "Invalid selection, using ${AVAILABLE_BRIDGES[0]}"
        INT_EGRESS_BRIDGE="${AVAILABLE_BRIDGES[0]}"
      fi
    fi

    # Get the IP of the selected egress bridge
    local DETECTED_EGRESS_IP=""
    if [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
      DETECTED_EGRESS_IP=$(sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" \
        "ip -4 addr show $INT_EGRESS_BRIDGE 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1" 2>/dev/null || echo "")
    fi

    if [ -n "$DETECTED_EGRESS_IP" ]; then
      info "Using egress bridge: $INT_EGRESS_BRIDGE ($DETECTED_EGRESS_IP)"
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

    # Check if system is multi-homed (egress bridge differs from default route interface)
    # If not multi-homed, PBR is unnecessary
    local IS_MULTI_HOMED=false
    local DEFAULT_ROUTE_IFACE=""
    INT_EGRESS_GW=""

    if [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
      # Get the interface that has the system's default route
      DEFAULT_ROUTE_IFACE=$(sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" \
        "ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1" 2>/dev/null || echo "")

      if [ -n "$DEFAULT_ROUTE_IFACE" ] && [ "$DEFAULT_ROUTE_IFACE" != "$INT_EGRESS_BRIDGE" ]; then
        IS_MULTI_HOMED=true
      fi
    fi

    if $IS_MULTI_HOMED; then
      echo
      info "Multi-homed system detected"
      info "(Default route is on $DEFAULT_ROUTE_IFACE, egress is on $INT_EGRESS_BRIDGE)"
      info "Policy-based routing will be configured to ensure correct gateway usage."
      echo
      info "Egress Gateway Configuration"
      echo

      # Detect gateway for egress bridge
      local DETECTED_EGRESS_GW=""
      # Try to infer from bridge IP (assume .1 gateway)
      if [ -n "$INT_EGRESS_IP" ]; then
        local EGRESS_BASE=$(echo "$INT_EGRESS_IP" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.')
        DETECTED_EGRESS_GW="${EGRESS_BASE}1"
      fi

      if [ -n "$DETECTED_EGRESS_GW" ]; then
        read -rp "$(question "Egress gateway for $INT_EGRESS_BRIDGE [$DETECTED_EGRESS_GW]: ")" INT_EGRESS_GW
        INT_EGRESS_GW=${INT_EGRESS_GW:-$DETECTED_EGRESS_GW}
      else
        read -rp "$(question "Egress gateway for $INT_EGRESS_BRIDGE: ")" INT_EGRESS_GW
        while [ -z "$INT_EGRESS_GW" ]; do
          warn "Egress gateway is required for policy-based routing"
          read -rp "$(question "Egress gateway: ")" INT_EGRESS_GW
        done
      fi
    else
      echo
      info "Single-gateway system detected - policy-based routing not required"
    fi
  else
    CREATE_SDN=false
    INT_CIDR=""
    INT_GATEWAY=""
    INT_EGRESS_BRIDGE=""
    INT_EGRESS_IP=""
    INT_EGRESS_GW=""
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
EOF

  if $ENABLE_HA; then
    cat <<EOF

DNS High Availability:
  VIP (failover IP): $HA_VIP
  Containers:        privileged (required for keepalived)
EOF
  fi

  if $ENABLE_TRAEFIK_HA; then
    cat <<EOF

Nomad Traefik High Availability:
  VIP (failover IP): $TRAEFIK_HA_VIP
  Traefik mode:      system job (runs on all Nomad nodes)
EOF
  fi

  cat <<EOF

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
    if [ -n "$INT_EGRESS_GW" ]; then
      cat <<EOF
  Egress Gateway:    $INT_EGRESS_GW (PBR enabled)
EOF
    else
      cat <<EOF
  Policy Routing:    not required (single gateway)
EOF
    fi
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
     --argjson ha_enabled "$ENABLE_HA" \
     --arg ha_vip "$HA_VIP" \
     --argjson create_sdn "$CREATE_SDN" \
     --arg int_cidr "$INT_CIDR" \
     --arg int_gw "$INT_GATEWAY" \
     --arg int_egress_bridge "$INT_EGRESS_BRIDGE" \
     --arg int_egress_ip "$INT_EGRESS_IP" \
     --arg int_egress_gw "$INT_EGRESS_GW" \
     --argjson traefik_ha_enabled "$ENABLE_TRAEFIK_HA" \
     --arg traefik_ha_vip "$TRAEFIK_HA_VIP" \
     --arg traefik_ha_vrrp_router_id "$TRAEFIK_HA_VRRP_ROUTER_ID" \
     --arg traefik_ha_vrrp_password "$TRAEFIK_HA_VRRP_PASSWORD" \
     --arg dns_postfix "$DNS_POSTFIX" \
     '. + {
       network: {
         external: {
           cidr: $ext_cidr,
           gateway: $ext_gw,
           dns_start_ip: $dns_start,
           services_start_ip: $svc_start,
           ha_enabled: $ha_enabled,
           ha_vip: $ha_vip
         },
         labnet: {
           enabled: $create_sdn,
           cidr: $int_cidr,
           gateway: $int_gw,
           egress_bridge: $int_egress_bridge,
           egress_ip: $int_egress_ip,
           egress_gateway: $int_egress_gw
         },
         nomad: {
           traefik_ha_enabled: $traefik_ha_enabled,
           traefik_ha_vip: $traefik_ha_vip,
           traefik_ha_vrrp_router_id: ($traefik_ha_vrrp_router_id | if . == "" then null else tonumber end),
           traefik_ha_vrrp_password: (if $traefik_ha_vrrp_password == "" then null else $traefik_ha_vrrp_password end)
         }
       },
       dns_postfix: $dns_postfix
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  success "Network configuration saved to $CLUSTER_INFO_FILE"
}