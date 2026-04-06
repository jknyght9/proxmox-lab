#!/usr/bin/env bash

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
  local DNS_HA_VIP=""
  local DNS_HA_ENABLED=""

  # Check for DNS HA VIP in cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_HA_ENABLED=$(jq -r '.network.external.ha_enabled // false' "$CLUSTER_INFO_FILE")
    DNS_HA_VIP=$(jq -r '.network.external.ha_vip // ""' "$CLUSTER_INFO_FILE" | cut -d'/' -f1)
  fi

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

  # Use DNS HA VIP if enabled, otherwise use dns-01 IP
  local DNS_TARGET_IP="$DNS_IP"
  if [ "$DNS_HA_ENABLED" = "true" ] && [ -n "$DNS_HA_VIP" ] && [ "$DNS_HA_VIP" != "null" ]; then
    DNS_TARGET_IP="$DNS_HA_VIP"
    echo "  DNS HA enabled, using VIP: $DNS_TARGET_IP"
  fi

  # Add "dns" alias pointing to VIP (if HA) or dns-01
  local DNS_ALIAS_JSON
  DNS_ALIAS_JSON="$(jq -c -n --arg ip "$DNS_TARGET_IP" --arg suffix "$DNS_POSTFIX" '["\($ip) dns dns.\($suffix)"]')"

  # Add Nomad service DNS records (services fronted by Traefik)
  # Use VIP if Traefik HA is enabled, otherwise use nomad01
  local NOMAD_IP=""
  local NOMAD02_IP=""
  local TRAEFIK_VIP=""
  local TRAEFIK_IP=""
  local NOMAD_SERVICES_JSON="[]"

  # Check for Traefik HA VIP in cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    TRAEFIK_VIP=$(jq -r '.network.nomad.traefik_ha_vip // ""' "$CLUSTER_INFO_FILE" | cut -d'/' -f1)
  fi

  if [ -s hosts.json ]; then
    NOMAD_IP=$(jq -r '.external[] | select(.hostname == "nomad01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    NOMAD02_IP=$(jq -r '.external[] | select(.hostname == "nomad02") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

    # Use VIP for Traefik services if HA is enabled, otherwise use nomad01
    if [ -n "$TRAEFIK_VIP" ] && [ "$TRAEFIK_VIP" != "null" ]; then
      TRAEFIK_IP="$TRAEFIK_VIP"
      echo "  Traefik HA enabled, using VIP: $TRAEFIK_IP"
    else
      TRAEFIK_IP="$NOMAD_IP"
    fi

    if [ -n "$TRAEFIK_IP" ] && [ "$TRAEFIK_IP" != "null" ]; then
      # Add common Nomad service names
      NOMAD_SERVICES_JSON="$(jq -c -n --arg ip "$TRAEFIK_IP" --arg suffix "$DNS_POSTFIX" '[
        "\($ip) vault vault.\($suffix)",
        "\($ip) auth auth.\($suffix)",
        "\($ip) traefik traefik.\($suffix)",
        "\($ip) status status.\($suffix)",
        "\($ip) nomad nomad.\($suffix)",
        "\($ip) pihole pihole.\($suffix)"
      ]')"
      echo "  Nomad services (via Traefik @ $TRAEFIK_IP):"
      echo "    - vault.$DNS_POSTFIX -> $TRAEFIK_IP"
      echo "    - auth.$DNS_POSTFIX -> $TRAEFIK_IP"
      echo "    - traefik.$DNS_POSTFIX -> $TRAEFIK_IP"
      echo "    - status.$DNS_POSTFIX -> $TRAEFIK_IP"
      echo "    - nomad.$DNS_POSTFIX -> $TRAEFIK_IP"
      echo "    - pihole.$DNS_POSTFIX -> $TRAEFIK_IP"
    fi
  fi

  # Add Kasm DNS record if deployed
  local KASM_RECORDS_JSON="[]"
  local KASM_IP=""
  if [ -s hosts.json ]; then
    KASM_IP=$(jq -r '.external[] | select(.hostname | startswith("kasm")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
    if [ -n "$KASM_IP" ] && [ "$KASM_IP" != "null" ]; then
      KASM_RECORDS_JSON="$(jq -c -n --arg ip "$KASM_IP" --arg suffix "$DNS_POSTFIX" '[
        "\($ip) kasm kasm.\($suffix)"
      ]')"
      echo "  Kasm Workspaces:"
      echo "    - kasm.$DNS_POSTFIX -> $KASM_IP"
    fi
  fi

  # Add Samba AD DNS records if AD is configured
  local AD_RECORDS_JSON="[]"
  local AD_REALM_FROM_CONFIG=""
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    AD_REALM_FROM_CONFIG=$(jq -r '.ad_config.realm // ""' "$CLUSTER_INFO_FILE")
  fi
  if [ -n "$NOMAD_IP" ] && [ "$NOMAD_IP" != "null" ] && [ -n "$AD_REALM_FROM_CONFIG" ] && [ "$AD_REALM_FROM_CONFIG" != "null" ]; then
    local AD_REALM_LOWER
    AD_REALM_LOWER=$(echo "$AD_REALM_FROM_CONFIG" | tr '[:upper:]' '[:lower:]')
    AD_RECORDS_JSON="$(jq -c -n --arg ip "$NOMAD_IP" --arg realm "$AD_REALM_LOWER" '[
      "\($ip) samba-dc01 samba-dc01.\($realm)"
    ]')"
    if [ -n "$NOMAD02_IP" ] && [ "$NOMAD02_IP" != "null" ]; then
      AD_RECORDS_JSON="$(echo "$AD_RECORDS_JSON" | jq -c --arg ip "$NOMAD02_IP" --arg realm "$AD_REALM_LOWER" \
        '. + ["\($ip) samba-dc02 samba-dc02.\($realm)"]')"
    fi
    echo "  Samba AD Domain Controllers:"
    echo "    - samba-dc01.$AD_REALM_LOWER -> $NOMAD_IP"
    if [ -n "$NOMAD02_IP" ] && [ "$NOMAD02_IP" != "null" ]; then
      echo "    - samba-dc02.$AD_REALM_LOWER -> $NOMAD02_IP"
    fi
  fi

  local ALL_DNS_RECORDS_JSON
  ALL_DNS_RECORDS_JSON="$(jq -c -n \
    --argjson a "$NODE_RECORDS_JSON" \
    --argjson b "$EXT_RECORDS_JSON" \
    --argjson c "$NODE_RECORDS_ALIAS_JSON" \
    --argjson d "$DNS_ALIAS_JSON" \
    --argjson e "$NOMAD_SERVICES_JSON" \
    --argjson f "$AD_RECORDS_JSON" \
    --argjson g "$KASM_RECORDS_JSON" \
    '$a + $b + $c + $d + $e + $f + $g | unique')"

  local RECORD_COUNT
  RECORD_COUNT=$(jq -r 'length' <<<"$ALL_DNS_RECORDS_JSON")

  echo
  info "Summary: $RECORD_COUNT A-records to add"

  doing "Updating Pi-hole @ $DNS_IP..."
  sshRunAdmin "$REMOTE_USER" "$DNS_IP" "pihole-FTL --config dns.hosts '$ALL_DNS_RECORDS_JSON' && pihole-FTL --config dns.cnameRecords '[\"ca.$DNS_POSTFIX,step-ca.$DNS_POSTFIX\"]'" \
    && success "Pi-hole DNS records updated" || error "Failed to update Pi-hole"

  # Trigger Nebula-Sync to propagate changes
  doing "Triggering Nebula-Sync to propagate to replicas..."
  if sshRunAdmin "$REMOTE_USER" "$DNS_IP" "systemctl start nebula-sync.service && systemctl status nebula-sync.service --no-pager | head -5"; then
    success "Sync triggered"
  else
    warn "Nebula-Sync sync failed or not configured - records may need manual sync"
  fi

  read -rp "$(question "Update Proxmox nodes to use this DNS server? [Y/n]: ")" UPDATE_PROXMOX
  UPDATE_PROXMOX=${UPDATE_PROXMOX:-Y}

  if [[ "$UPDATE_PROXMOX" =~ ^[Yy]$ ]]; then
    # Disable Tailscale DNS if present (prevents overwriting resolv.conf)
    disableTailscaleDNS

    doing "Updating Proxmox nodes' DNS settings..."
    for i in "${!CLUSTER_NODES[@]}"; do
      local node="${CLUSTER_NODES[$i]}"
      local ip="${CLUSTER_NODE_IPS[$i]}"
      sshRun "$REMOTE_USER" "$ip" "sed -i '/^nameserver/d' /etc/resolv.conf && echo 'nameserver $DNS_TARGET_IP' >> /etc/resolv.conf"
      echo "  - $node: DNS set to $DNS_TARGET_IP"
    done
    success "Proxmox DNS settings updated"
  fi
}