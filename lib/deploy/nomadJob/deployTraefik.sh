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
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo mkdir -p /srv/gluster/nomad-data/traefik /srv/gluster/nomad-data/certs && sudo chmod 755 /srv/gluster/nomad-data/traefik /srv/gluster/nomad-data/certs"

  # Copy CA certificate for ACME trust
  doing "Copying CA certificate for Traefik..."
  local CA_IP
  CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -n "$CA_IP" ] && [ "$CA_IP" != "null" ]; then
    # Fetch root CA and copy to GlusterFS
    if curl -sk "https://$CA_IP/roots.pem" -o /tmp/root_ca.crt 2>/dev/null; then
      scpTo "/tmp/root_ca.crt" "$VM_USER" "$NOMAD_IP" "/tmp/root_ca.crt"
      sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo cp /tmp/root_ca.crt /srv/gluster/nomad-data/certs/root_ca.crt && sudo chmod 644 /srv/gluster/nomad-data/certs/root_ca.crt"
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
    startTraefikHA
  fi

  # Update DNS records for traefik
  updateDNSRecords

  displayDeploymentSummary

  success "Traefik deployment complete!"
}

# startTraefikHA - Start keepalived for Traefik HA
#
# Keepalived is pre-installed via Packer and configured via cloud-init.
# This function starts keepalived on all Nomad nodes after Traefik is deployed.
function startTraefikHA() {
  doing "Starting keepalived for Traefik HA..."

  local VIP
  VIP=$(jq -r '.network.nomad.traefik_ha_vip // ""' "$CLUSTER_INFO_FILE")

  if [ -z "$VIP" ]; then
    error "Traefik HA VIP not configured in cluster-info.json"
    return 1
  fi

  # Get all Nomad node IPs
  local node_ips=()
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && node_ips+=("$ip")
  done < <(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json | sort | cut -d'/' -f1)

  if [ ${#node_ips[@]} -lt 1 ]; then
    error "No Nomad nodes found in hosts.json"
    return 1
  fi

  # Start keepalived on each node
  for ip in "${node_ips[@]}"; do
    sshRunAdmin "$VM_USER" "$ip" "sudo systemctl enable keepalived && sudo systemctl restart keepalived" && \
      info "  Started keepalived on $ip" || \
      warn "  Failed to start keepalived on $ip"
  done

  # Wait for VRRP election
  sleep 3

  # Verify VIP is active
  local vip_ip
  vip_ip=$(echo "$VIP" | cut -d'/' -f1)
  doing "Verifying VIP ($vip_ip) is active..."

  local vip_found=false
  for ip in "${node_ips[@]}"; do
    if sshRunAdmin "$VM_USER" "$ip" "ip addr show eth0 | grep -q '$vip_ip'" 2>/dev/null; then
      success "VIP $vip_ip is active on $ip"
      vip_found=true
      break
    fi
  done

  if ! $vip_found; then
    warn "VIP not found on any node - check keepalived logs: journalctl -u keepalived"
  fi
}

# Check if Traefik is deployed as a Nomad job
function isTraefikDeployed() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  local status
  status=$(sshRunAdmin "$VM_USER" "$nomad_ip" "nomad job status traefik 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}