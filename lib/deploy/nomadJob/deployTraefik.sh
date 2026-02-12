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

  # Deploy Traefik using the generic Nomad job deployer
  if ! deployNomadJob "traefik" "nomad/jobs/traefik.nomad.hcl" "/srv/gluster/nomad-data/traefik"; then
    return 1
  fi

  # Get Nomad IP for display
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

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