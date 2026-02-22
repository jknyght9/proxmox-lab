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

  # Update DNS records for traefik
  updateDNSRecords

  displayDeploymentSummary

  success "Traefik deployment complete!"
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