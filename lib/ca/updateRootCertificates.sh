#!/usr/bin/env bash

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
  MEMBERS_JSON="$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" 'cat /etc/pve/.members')"
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
    sshRun "$REMOTE_USER" "$name" "rm -f /usr/local/share/ca-certificates/proxmox-lab*.crt; rm -f /etc/ssl/certs/proxmox-lab*.pem"
    scpTo "proxmox-lab-root-ca.crt" "$REMOTE_USER" "$name" "/usr/local/share/ca-certificates/proxmox-lab-root-ca.crt"
    sshRun "$REMOTE_USER" "$name" "set -e; update-ca-certificates --fresh; systemctl reload pveproxy || systemctl restart pveproxy"
  done

  # Configure all nodes to use Pi-hole as DNS (required for ACME hostname resolution)
  doing "Configuring DNS on all nodes to use Pi-hole ($DNS_IP)"
  for node_ip in "${NODE_IPS[@]}"; do
    sshRun "$REMOTE_USER" "$node_ip" "echo 'nameserver ${DNS_IP}' > /etc/resolv.conf && echo 'search ${DNS_POSTFIX}' >> /etc/resolv.conf" \
      || warn "Failed to configure DNS on $node_ip"
  done

  # Verify DNS resolution works before proceeding with ACME
  doing "Verifying DNS resolution for ca.${DNS_POSTFIX}..."
  local dns_ok=false
  for attempt in $(seq 1 10); do
    local resolved_ip
    resolved_ip=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "dig +short ca.${DNS_POSTFIX} 2>/dev/null | head -1" || echo "")
    if [ -n "$resolved_ip" ]; then
      success "ca.${DNS_POSTFIX} resolves to $resolved_ip"
      dns_ok=true
      break
    fi
    echo "  Waiting for DNS propagation... (attempt $attempt/10)"
    sleep 2
  done

  if [ "$dns_ok" != "true" ]; then
    warn "DNS resolution failed for ca.${DNS_POSTFIX}"
    warn "Falling back to IP-based ACME directory (may fail cert verification)"
    ACME_DIR="https://${CA_IP}/acme/acme/directory"
  fi

  doing "Registering ACME account 'default' against Step CA directory"
  sshRun "$REMOTE_USER" "$PROXMOX_HOST" "pvenode acme account deactivate default 2>/dev/null || true; rm -f /etc/pve/priv/acme/default 2>/dev/null || true; pvenode acme account register default admin@example.com --directory '$ACME_DIR'"

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

    sshRun "$REMOTE_USER" "$DNS_IP" "pihole-FTL --config dns.hosts '$TEMP_RECORDS'" || { warn "Failed to update DNS for $name"; continue; }

    # Brief pause for DNS propagation
    sleep 2

    # Order certificate
    doing "    Ordering certificate for $name"
    sshRun "$REMOTE_USER" "$ip" "set -e; pvenode config set --delete acme 2>/dev/null || true; pvenode config set --acme \"$acme_map\"; pvenode acme cert order -force" \
      || { warn "SSH/ACME failed for $name ($ip)"; continue; }

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

  sshRun "$REMOTE_USER" "$DNS_IP" "pihole-FTL --config dns.hosts '$FINAL_RECORDS'" || warn "Failed to restore round-robin DNS"

  success "Root CA installed on all nodes; ACME certs issued; round-robin DNS restored."
}