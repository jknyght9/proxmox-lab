#!/usr/bin/env bash

# deployTraefikOnly - Deploy Traefik reverse proxy as a Nomad system job
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Critical services deployed (DNS, CA)
#   - cluster-info.json and hosts.json present
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, TRAEFIK_DIR
# Arguments: None
# Returns: 0 on success, 1 on failure
function deployTraefikOnly() {
  cat <<EOF

############################################################################
Traefik Load Balancer Deployment

Deploying Traefik as a Nomad system job for load balancing and service discovery.
Assumes Nomad cluster is already running.
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureCriticalServices || return 1
  ensureNomadCluster || return 1

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  # Create storage directory for Traefik
  doing "Preparing Traefik storage directory..."
  sshRun "$VM_USER" "$NOMAD_IP" "sudo mkdir -p /srv/gluster/nomad-data/traefik /srv/gluster/nomad-data/certs && sudo chmod 755 /srv/gluster/nomad-data/traefik /srv/gluster/nomad-data/certs"

  # Copy CA certificate for ACME trust
  doing "Copying CA certificate for Traefik..."
  local CA_IP
  CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -n "$CA_IP" ] && [ "$CA_IP" != "null" ]; then
    # Fetch root CA and copy to GlusterFS
    if curl -sk "https://$CA_IP/roots.pem" -o /tmp/root_ca.crt 2>/dev/null; then
      scpTo "/tmp/root_ca.crt" "$VM_USER" "$NOMAD_IP" "/tmp/root_ca.crt"
      sshRun "$VM_USER" "$NOMAD_IP" "sudo cp /tmp/root_ca.crt /srv/gluster/nomad-data/certs/root_ca.crt && sudo chmod 644 /srv/gluster/nomad-data/certs/root_ca.crt"
      success "CA certificate installed for Traefik"
    else
      warn "Could not fetch CA certificate from $CA_IP"
    fi
  else
    warn "step-ca not found in hosts.json, skipping CA certificate"
  fi

  # Deploy Traefik using the generic Nomad job deployer
  if ! deployNomadJob "traefik" "nomad/jobs/traefik.nomad.hcl" "/srv/gluster/nomad-data/traefik"; then
    return 1
  fi

  # Configure keepalived on all Nomad nodes if Traefik HA is enabled
  local TRAEFIK_HA_ENABLED="false"
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    TRAEFIK_HA_ENABLED=$(jq -r '.network.nomad.traefik_ha_enabled // false' "$CLUSTER_INFO_FILE")
  fi

  if [ "$TRAEFIK_HA_ENABLED" = "true" ]; then
    configureTraefikHA
  fi

  # Update DNS records for traefik
  updateDNSRecords

  displayDeploymentSummary

  success "Traefik deployment complete!"
}

# configureTraefikHA - Install and configure keepalived for Traefik HA
#
# Installs keepalived on all Nomad nodes and configures VRRP for VIP failover.
# Configuration is read from cluster-info.json:
#   - network.nomad.traefik_ha_vip: VIP address with CIDR
#   - network.nomad.traefik_ha_vrrp_router_id: VRRP router ID (default: 53)
#   - network.nomad.traefik_ha_vrrp_password: VRRP auth password (default: traefik)
#
# Priority is assigned based on node order: nomad01=101, nomad02=100, nomad03=99
function configureTraefikHA() {
  doing "Configuring Traefik HA with keepalived..."

  # Read HA config from cluster-info.json
  local VIP VRRP_ROUTER_ID VRRP_PASSWORD
  VIP=$(jq -r '.network.nomad.traefik_ha_vip // ""' "$CLUSTER_INFO_FILE")
  VRRP_ROUTER_ID=$(jq -r '.network.nomad.traefik_ha_vrrp_router_id // 53' "$CLUSTER_INFO_FILE")
  VRRP_PASSWORD=$(jq -r '.network.nomad.traefik_ha_vrrp_password // "traefik"' "$CLUSTER_INFO_FILE")

  if [ -z "$VIP" ]; then
    error "Traefik HA VIP not configured in cluster-info.json"
    return 1
  fi

  # Get all Nomad node IPs (sorted by hostname for consistent priority)
  local node_ips=()
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && node_ips+=("$ip")
  done < <(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json | sort | cut -d'/' -f1)

  if [ ${#node_ips[@]} -lt 1 ]; then
    error "No Nomad nodes found in hosts.json"
    return 1
  fi

  info "  VIP: $VIP"
  info "  VRRP Router ID: $VRRP_ROUTER_ID"
  info "  Nodes: ${node_ips[*]}"

  # Install and configure keepalived on each node
  local node_index=0
  for ip in "${node_ips[@]}"; do
    local priority=$((101 - node_index))
    local state="BACKUP"
    [ $node_index -eq 0 ] && state="MASTER"

    doing "  Configuring keepalived on $ip (priority=$priority, state=$state)..."

    # Install keepalived if not present
    sshRun "$VM_USER" "$ip" "dpkg -l keepalived >/dev/null 2>&1 || sudo apt-get update && sudo apt-get install -y keepalived"

    # Create health check script
    sshRun "$VM_USER" "$ip" "cat <<'HEALTHSCRIPT' | sudo tee /usr/local/bin/check-traefik-health.sh > /dev/null
#!/bin/bash
# Health check for Traefik - used by keepalived to determine VIP ownership
curl -sf http://127.0.0.1:8081/ping > /dev/null 2>&1
exit \$?
HEALTHSCRIPT
sudo chmod +x /usr/local/bin/check-traefik-health.sh"

    # Create keepalived config
    sshRun "$VM_USER" "$ip" "cat <<KEEPALIVED | sudo tee /etc/keepalived/keepalived.conf > /dev/null
vrrp_script check_traefik {
    script \"/usr/local/bin/check-traefik-health.sh\"
    interval 2
    weight -20
    fall 3
    rise 2
}

vrrp_instance TRAEFIK_VIP {
    state $state
    interface eth0
    virtual_router_id $VRRP_ROUTER_ID
    priority $priority
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass $VRRP_PASSWORD
    }

    virtual_ipaddress {
        $VIP
    }

    track_script {
        check_traefik
    }
}
KEEPALIVED"

    # Enable and start keepalived
    sshRun "$VM_USER" "$ip" "sudo systemctl enable keepalived && sudo systemctl restart keepalived"

    ((node_index++))
  done

  # Wait for VRRP election
  sleep 3

  # Verify VIP is active on one of the nodes
  local vip_ip
  vip_ip=$(echo "$VIP" | cut -d'/' -f1)
  doing "Verifying VIP ($vip_ip) is active..."

  local vip_found=false
  for ip in "${node_ips[@]}"; do
    if sshRun "$VM_USER" "$ip" "ip addr show eth0 | grep -q '$vip_ip'" 2>/dev/null; then
      success "VIP $vip_ip is active on $ip"
      vip_found=true
      break
    fi
  done

  if ! $vip_found; then
    warn "VIP not found on any node - check keepalived logs: journalctl -u keepalived"
  fi

  success "Traefik HA configured with keepalived"
}

# Check if Traefik is deployed as a Nomad job
function isTraefikDeployed() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  local status
  status=$(sshRun "$VM_USER" "$nomad_ip" "nomad job status traefik 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}