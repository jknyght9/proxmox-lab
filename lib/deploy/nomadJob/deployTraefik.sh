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

  # Create storage directories for Traefik
  doing "Preparing Traefik storage directory..."
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo mkdir -p /srv/gluster/nomad-data/traefik/config /srv/gluster/nomad-data/traefik/tls && sudo chmod 755 /srv/gluster/nomad-data/traefik /srv/gluster/nomad-data/traefik/config /srv/gluster/nomad-data/traefik/tls"

  # Authentik middleware config is now deployed by Terraform (vm-nomad module)
  # via templatefile() to GlusterFS during initial cluster setup.
  # Re-running Traefik deployment will use the existing config on disk.

  # Issue a wildcard TLS certificate from Vault PKI for all services
  # behind Traefik. This replaces ACME entirely — Vault 1.21.x has a
  # bug where the ACME new-nonce endpoint doesn't return the required
  # Replay-Nonce header, so we issue certs directly via the PKI API.
  # Re-running option 5 reissues the cert (1-year TTL).
  if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
    local VAULT_ADDR ROOT_TOKEN
    VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
    ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

    if [ -n "$VAULT_ADDR" ] && [ -n "$ROOT_TOKEN" ]; then
      doing "Issuing wildcard TLS certificate from Vault PKI (*.${DNS_POSTFIX})..."

      local CERT_PAYLOAD
      CERT_PAYLOAD=$(jq -n \
        --arg cn "*.${DNS_POSTFIX}" \
        --arg alt "${DNS_POSTFIX}" \
        '{
          common_name: $cn,
          alt_names: $alt,
          ttl: "8760h"
        }')

      local CERT_RESPONSE
      CERT_RESPONSE=$(curl -skf -X POST "${VAULT_ADDR}/v1/pki_int/issue/acme-certs" \
        -H "X-Vault-Token: $ROOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$CERT_PAYLOAD" 2>&1)

      local CERT KEY CHAIN
      CERT=$(echo "$CERT_RESPONSE" | jq -r '.data.certificate // empty')
      KEY=$(echo "$CERT_RESPONSE" | jq -r '.data.private_key // empty')
      CHAIN=$(echo "$CERT_RESPONSE" | jq -r '.data.ca_chain // [] | join("\n")')

      if [ -z "$CERT" ] || [ -z "$KEY" ]; then
        error "Failed to issue wildcard cert from Vault PKI"
        warn "Traefik will start without TLS certs"
      else
        # Write full chain (leaf + intermediate + root) and key
        local TMPDIR
        TMPDIR=$(mktemp -d)
        printf '%s\n%s\n' "$CERT" "$CHAIN" > "$TMPDIR/cert.pem"
        printf '%s\n' "$KEY" > "$TMPDIR/key.pem"

        scpToAdmin "$TMPDIR/cert.pem" "$VM_USER" "$NOMAD_IP" "/tmp/traefik-cert.pem"
        scpToAdmin "$TMPDIR/key.pem" "$VM_USER" "$NOMAD_IP" "/tmp/traefik-key.pem"
        sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo cp /tmp/traefik-cert.pem /srv/gluster/nomad-data/traefik/tls/cert.pem && sudo cp /tmp/traefik-key.pem /srv/gluster/nomad-data/traefik/tls/key.pem && sudo chmod 644 /srv/gluster/nomad-data/traefik/tls/cert.pem /srv/gluster/nomad-data/traefik/tls/key.pem"
        rm -rf "$TMPDIR"
        success "Wildcard TLS certificate installed (valid 1 year)"

        # Generate Traefik dynamic config that sets this as the default cert.
        # The file provider watches /data/traefik/config/ and picks this up.
        doing "Deploying TLS configuration for Traefik..."
        cat > /tmp/traefik-tls.yml <<'TLSYML'
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /data/traefik/tls/cert.pem
        keyFile: /data/traefik/tls/key.pem
TLSYML
        scpToAdmin "/tmp/traefik-tls.yml" "$VM_USER" "$NOMAD_IP" "/tmp/tls.yml"
        sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo cp /tmp/tls.yml /srv/gluster/nomad-data/traefik/config/tls.yml && sudo chmod 644 /srv/gluster/nomad-data/traefik/config/tls.yml"
        rm -f /tmp/traefik-tls.yml
        success "TLS configuration deployed"
      fi
    else
      warn "Vault credentials incomplete - skipping TLS cert issuance"
    fi
  else
    warn "$VAULT_CREDENTIALS_FILE not found - Traefik will start without TLS certs"
  fi

  # Determine DNS server IP (VIP if HA enabled, otherwise dns-01)
  local DNS_SERVER
  DNS_SERVER=$(jq -r '.network.external.ha_vip // ""' "$CLUSTER_INFO_FILE" 2>/dev/null | cut -d'/' -f1)
  if [ -z "$DNS_SERVER" ] || [ "$DNS_SERVER" = "null" ]; then
    DNS_SERVER=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  fi
  if [ -z "$DNS_SERVER" ] || [ "$DNS_SERVER" = "null" ]; then
    DNS_SERVER="$NOMAD_IP"
    warn "Could not determine DNS server, using Nomad IP: $DNS_SERVER"
  fi

  # Deploy Traefik using the generic Nomad job deployer
  if ! deployNomadJob "traefik" "nomad/jobs/traefik.nomad.hcl" "/srv/gluster/nomad-data/traefik" "-var dns_server=${DNS_SERVER}"; then
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