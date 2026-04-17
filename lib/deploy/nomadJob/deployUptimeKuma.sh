#!/usr/bin/env bash

# deployUptimeKumaOnly - Deploy Uptime Kuma monitoring as a Nomad service
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Traefik deployed (for ingress)
#   - GlusterFS mounted at NOMAD_DATA_DIR
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, SCRIPT_DIR
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates Uptime Kuma storage directory on GlusterFS
#   - Deploys Nomad job
#   - Updates DNS records
function deployUptimeKumaOnly() {
  cat <<EOF

############################################################################
Uptime Kuma Monitoring Deployment

Deploying Uptime Kuma for service health monitoring.
Requires: Nomad cluster running, Traefik for ingress
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureCriticalServices || return 1
  ensureNomadCluster || return 1

  # Check if Traefik is deployed
  if ! isTraefikDeployed; then
    warn "Traefik is not deployed. Uptime Kuma will work but won't be accessible via HTTPS."
    read -rp "$(question "Continue anyway? [y/N]: ")" CONTINUE
    CONTINUE=${CONTINUE:-N}
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
      warn "Deployment cancelled. Deploy Traefik first (option 7)."
      return 1
    fi
  fi

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  local UPTIME_KUMA_DIR="/srv/gluster/nomad-data/uptime-kuma"

  # Create storage directory
  doing "Preparing Uptime Kuma storage directory..."

  if ! sshScriptAdmin "$VM_USER" "$NOMAD_IP" <<REMOTE_SCRIPT
    UPTIME_KUMA_DIR="$UPTIME_KUMA_DIR"

    # Create storage directory
    sudo mkdir -p "\$UPTIME_KUMA_DIR"
    sudo chmod 777 "\$UPTIME_KUMA_DIR"

    # Verify directory is writable
    if sudo touch "\$UPTIME_KUMA_DIR/.write_test" && sudo rm "\$UPTIME_KUMA_DIR/.write_test"; then
      echo "Uptime Kuma storage directory prepared and writable"
    else
      echo "ERROR: Uptime Kuma storage directory is not writable"
      exit 1
    fi
REMOTE_SCRIPT
  then
    error "Failed to prepare Uptime Kuma storage"
    return 1
  fi

  # Deploy Uptime Kuma using the generic Nomad job deployer
  if ! deployNomadJob "uptime-kuma" "nomad/jobs/uptime-kuma.nomad.hcl" "$UPTIME_KUMA_DIR" "-var dns_postfix=${DNS_POSTFIX}"; then
    return 1
  fi

  # Wait for Uptime Kuma to become healthy
  doing "Waiting for Uptime Kuma to become healthy..."

  local UPTIME_KUMA_READY=false
  for attempt in {1..30}; do
    if curl -sf --connect-timeout 2 --max-time 5 "http://$NOMAD_IP:3001/" >/dev/null 2>&1; then
      UPTIME_KUMA_READY=true
      break
    fi
    sleep 2
  done

  if [ "$UPTIME_KUMA_READY" = "false" ]; then
    warn "Uptime Kuma did not respond within 60 seconds, but deployment may still succeed."
    info "Check Nomad logs: nomad alloc logs -job uptime-kuma"
  else
    success "Uptime Kuma is responding"
  fi

  # Update DNS records
  updateDNSRecords

  displayDeploymentSummary

  echo
  info "Uptime Kuma is running at: https://status.${DNS_POSTFIX}/ (via Traefik)"
  info "Or directly at: http://${NOMAD_IP}:3001/"
  echo
  info "Next steps:"
  info "  1. Open https://status.${DNS_POSTFIX}/ in your browser"
  info "  2. Create an admin account (first user becomes admin)"
  info "  3. Add monitors for your services:"
  echo
  info "Suggested monitors:"
  info "  - Vault: http://nomad01:8200/v1/sys/health?uninitcode=200&sealedcode=200"
  info "  - Authentik: http://nomad01:9000/-/health/live/"
  info "  - Traefik: http://nomad01:8081/ping"
  info "  - Nomad: http://nomad01:4646/v1/status/leader"
  info "  - Pi-hole: http://dns-01:80/admin/"
  info "  - step-ca: https://step-ca.${DNS_POSTFIX}/health"
  echo

  success "Uptime Kuma deployment complete!"
}

# Check if Uptime Kuma is deployed as a Nomad job
function isUptimeKumaDeployed() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  local status
  status=$(sshRunAdmin "$VM_USER" "$nomad_ip" "nomad job status uptime-kuma 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}
