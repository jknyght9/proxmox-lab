#!/usr/bin/env bash

# deployTailscaleOnly - Deploy Tailscale subnet router as a Nomad service
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - GlusterFS mounted at NOMAD_DATA_DIR
#   - Tailscale auth key (or interactive login after deployment)
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, CLUSTER_INFO_FILE
# Arguments: None
# Returns: 0 on success, 1 on failure
function deployTailscaleOnly() {
  cat <<EOF

############################################################################
Tailscale Subnet Router Deployment

Deploying Tailscale as a Nomad service for remote access to lab network.
Requires: Nomad cluster running
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureNomadCluster || return 1

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  # Get subnet from cluster-info.json
  local TAILSCALE_SUBNET=""
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    TAILSCALE_SUBNET=$(jq -r '.network.external.cidr // ""' "$CLUSTER_INFO_FILE")
  fi

  if [ -z "$TAILSCALE_SUBNET" ] || [ "$TAILSCALE_SUBNET" = "null" ]; then
    read -rp "$(question "Enter subnet to advertise (e.g., 10.1.50.0/24): ")" TAILSCALE_SUBNET
  fi

  info "Will advertise subnet: $TAILSCALE_SUBNET"

  # Create storage directory
  doing "Preparing Tailscale state directory..."
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo mkdir -p /srv/gluster/nomad-data/tailscale && sudo chmod 755 /srv/gluster/nomad-data/tailscale"

  # Export for envsubst
  export TAILSCALE_SUBNET

  # Deploy using the generic Nomad job deployer
  doing "Deploying Tailscale job..."

  # Render template with environment variables
  envsubst '${TAILSCALE_SUBNET}' < "nomad/jobs/tailscale.nomad.hcl" > "/tmp/tailscale-rendered.nomad.hcl"

  # Copy to Nomad node
  scpToAdmin "/tmp/tailscale-rendered.nomad.hcl" "$VM_USER" "$NOMAD_IP" "/tmp/tailscale.nomad.hcl"

  # Run the job
  if ! sshRunAdmin "$VM_USER" "$NOMAD_IP" "nomad job run /tmp/tailscale.nomad.hcl"; then
    error "Failed to deploy Tailscale"
    return 1
  fi

  rm -f "/tmp/tailscale-rendered.nomad.hcl"

  # Wait for container to start
  sleep 5

  echo
  warn "Tailscale container is running but needs authentication!"
  echo
  info "To authenticate, run:"
  echo "  ssh labadmin@$NOMAD_IP"
  echo "  docker exec -it \$(docker ps -q --filter ancestor=tailscale/tailscale:latest) tailscale up --advertise-routes=$TAILSCALE_SUBNET --accept-routes"
  echo
  info "Then approve the subnet route in Tailscale Admin Console:"
  echo "  https://login.tailscale.com/admin/machines"
  echo "  Find the machine → Edit route settings → Approve routes"
  echo

  success "Tailscale deployment complete (authentication required)!"
}
