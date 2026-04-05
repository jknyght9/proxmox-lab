#!/usr/bin/env bash

# deployStaticAssetsOnly - Deploy nginx static asset server as a Nomad service
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Traefik deployed for ingress
#   - GlusterFS mounted at NOMAD_DATA_DIR
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER
# Arguments: None
# Returns: 0 on success, 1 on failure
function deployStaticAssetsOnly() {
  cat <<EOF

############################################################################
Static Assets Server Deployment

Deploying nginx as a Nomad service for hosting static assets (branding, etc).
Requires: Nomad cluster running, Traefik for ingress
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureCriticalServices || return 1
  ensureNomadCluster || return 1

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  # Create storage directory
  doing "Preparing static assets directory..."
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo mkdir -p /srv/gluster/nomad-data/static-assets && sudo chmod 755 /srv/gluster/nomad-data/static-assets"

  # Deploy using the generic Nomad job deployer
  if ! deployNomadJob "static-assets" "nomad/jobs/static-assets.nomad.hcl" "/srv/gluster/nomad-data/static-assets"; then
    return 1
  fi

  # Update DNS records
  updateDNSRecords

  displayDeploymentSummary

  echo
  info "Static assets server is running at: https://assets.${DNS_POSTFIX}/"
  info "Upload files to: /srv/gluster/nomad-data/static-assets/"
  echo

  success "Static assets server deployment complete!"
}
