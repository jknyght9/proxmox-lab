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
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo mkdir -p /srv/gluster/nomad-data/traefik/config /srv/gluster/nomad-data/certs && sudo chmod 755 /srv/gluster/nomad-data/traefik /srv/gluster/nomad-data/traefik/config /srv/gluster/nomad-data/certs"

  # Copy Authentik middleware config (for forward auth + static services)
  if [ -f "nomad/config/traefik/authentik.yml" ]; then
    doing "Deploying Authentik forward auth middleware config..."
    # Get Nomad node IPs
    local NOMAD01_IP NOMAD02_IP NOMAD03_IP DNS01_IP
    NOMAD01_IP=$(jq -r '.external[] | select(.hostname == "nomad01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    NOMAD02_IP=$(jq -r '.external[] | select(.hostname == "nomad02") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    NOMAD03_IP=$(jq -r '.external[] | select(.hostname == "nomad03") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    DNS01_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    # Default to nomad01 if others don't exist
    [ -z "$NOMAD02_IP" ] || [ "$NOMAD02_IP" = "null" ] && NOMAD02_IP="$NOMAD01_IP"
    [ -z "$NOMAD03_IP" ] || [ "$NOMAD03_IP" = "null" ] && NOMAD03_IP="$NOMAD01_IP"
    export DNS_POSTFIX NOMAD01_IP NOMAD02_IP NOMAD03_IP DNS01_IP
    envsubst '${DNS_POSTFIX} ${NOMAD01_IP} ${NOMAD02_IP} ${NOMAD03_IP} ${DNS01_IP}' < "nomad/config/traefik/authentik.yml" > "/tmp/authentik-middleware.yml"
    scpToAdmin "/tmp/authentik-middleware.yml" "$VM_USER" "$NOMAD_IP" "/tmp/authentik.yml"
    sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo cp /tmp/authentik.yml /srv/gluster/nomad-data/traefik/config/authentik.yml && sudo chmod 644 /srv/gluster/nomad-data/traefik/config/authentik.yml"
    rm -f "/tmp/authentik-middleware.yml"
    success "Authentik middleware config deployed (forward auth → $NOMAD01_IP:9000)"
  fi

  # Register Vault policy + jwt-nomad role for Traefik so the job can
  # render the root CA at runtime via a template stanza (Vault = single
  # source of truth; no bind-mounted copies drifting on GlusterFS).
  if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
    local VAULT_ADDR ROOT_TOKEN
    VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
    ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

    if [ -n "$VAULT_ADDR" ] && [ -n "$ROOT_TOKEN" ]; then
      doing "Creating Vault policy for Traefik..."
      local TRAEFIK_POLICY
      TRAEFIK_POLICY=$(cat "$SCRIPT_DIR/nomad/vault-policies/traefik.hcl")
      if ! curl -sf --connect-timeout 5 --max-time 10 -X PUT "${VAULT_ADDR}/v1/sys/policies/acl/traefik" \
        -H "X-Vault-Token: $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"policy\": $(echo "$TRAEFIK_POLICY" | jq -Rs .)}" > /dev/null; then
        warn "Failed to create traefik policy"
      else
        success "Created traefik policy"
      fi

      doing "Creating Vault role 'traefik' for WIF..."
      local TRAEFIK_ROLE
      TRAEFIK_ROLE=$(cat <<'ROLE_JSON'
{
  "role_type": "jwt",
  "bound_audiences": ["vault.io"],
  "user_claim": "/nomad_job_id",
  "user_claim_json_pointer": true,
  "claim_mappings": {
    "nomad_namespace": "nomad_namespace",
    "nomad_job_id": "nomad_job_id",
    "nomad_task": "nomad_task"
  },
  "token_type": "service",
  "token_policies": ["traefik"],
  "token_period": "1h",
  "token_ttl": "1h",
  "bound_claims": {
    "nomad_job_id": "traefik"
  }
}
ROLE_JSON
)
      if ! curl -sf -X POST "${VAULT_ADDR}/v1/auth/jwt-nomad/role/traefik" \
        -H "X-Vault-Token: $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$TRAEFIK_ROLE" > /dev/null; then
        warn "Failed to create traefik Vault role"
      else
        success "Created Vault role 'traefik'"
      fi
    else
      warn "Vault credentials incomplete - skipping Traefik Vault setup"
    fi
  else
    warn "$VAULT_CREDENTIALS_FILE not found - Traefik will not be able to render CA from Vault"
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