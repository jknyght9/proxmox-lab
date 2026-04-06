#!/usr/bin/env bash

# deployTailscaleOnly - Deploy Tailscale HA subnet routers as a Nomad system job
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Vault deployed and configured
#   - GlusterFS mounted at NOMAD_DATA_DIR
#   - Tailscale auth key (reusable, pre-authorized, 90-day expiry)
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, CLUSTER_INFO_FILE, VAULT_CREDENTIALS_FILE
# Arguments: None
# Returns: 0 on success, 1 on failure
function deployTailscaleOnly() {
  cat <<EOF

############################################################################
Tailscale HA Subnet Router Deployment

Deploying Tailscale as a Nomad system job for remote access to lab network.
Runs on ALL Nomad nodes for high availability.
Requires: Nomad cluster, Vault with auth key stored
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureNomadCluster || return 1

  # Get all Nomad node IPs
  local ALL_NOMAD_IPS
  ALL_NOMAD_IPS=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json | cut -d'/' -f1)

  local NOMAD_IP
  NOMAD_IP=$(echo "$ALL_NOMAD_IPS" | head -1)

  # Get subnet from cluster-info.json
  local TAILSCALE_SUBNET=""
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    TAILSCALE_SUBNET=$(jq -r '.network.external.cidr // ""' "$CLUSTER_INFO_FILE")
  fi

  if [ -z "$TAILSCALE_SUBNET" ] || [ "$TAILSCALE_SUBNET" = "null" ]; then
    read -rp "$(question "Enter subnet to advertise (e.g., 10.1.50.0/24): ")" TAILSCALE_SUBNET
  fi

  info "Will advertise subnet: $TAILSCALE_SUBNET (on all Nomad nodes)"

  # Check Vault for existing auth key
  doing "Checking Vault for Tailscale auth key..."

  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials not found. Deploy Vault first."
    return 1
  fi

  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  local EXISTING_KEY
  EXISTING_KEY=$(curl -sf -H "X-Vault-Token: $ROOT_TOKEN" "$VAULT_ADDR/v1/secret/data/tailscale" 2>/dev/null | jq -r '.data.data.auth_key // empty')

  if [ -z "$EXISTING_KEY" ]; then
    echo
    warn "No Tailscale auth key found in Vault."
    echo
    info "Generate one at: https://login.tailscale.com/admin/settings/keys"
    echo "  → Generate auth key"
    echo "  → Reusable: YES"
    echo "  → Pre-authorized: YES (optional, skips approval)"
    echo "  → Expiry: 90 days"
    echo "  → Tags: tag:subnet-router (optional)"
    echo
    read -rsp "$(question "Paste your Tailscale auth key: ")" TS_AUTH_KEY
    echo

    if [ -z "$TS_AUTH_KEY" ]; then
      error "No auth key provided"
      return 1
    fi

    # Store in Vault
    doing "Storing auth key in Vault..."
    if ! curl -sf -X POST "$VAULT_ADDR/v1/secret/data/tailscale" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"data\": {\"auth_key\": \"$TS_AUTH_KEY\"}}" > /dev/null; then
      error "Failed to store auth key in Vault"
      return 1
    fi
    success "Auth key stored in Vault at secret/tailscale"
  else
    success "Found existing auth key in Vault"
  fi

  # Create Vault policy for Tailscale
  doing "Creating Vault policy for Tailscale..."
  local POLICY
  POLICY=$(cat "$SCRIPT_DIR/nomad/vault-policies/tailscale.hcl")
  curl -sf -X PUT "$VAULT_ADDR/v1/sys/policies/acl/tailscale" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"policy\": $(echo "$POLICY" | jq -Rs .)}" > /dev/null

  # Create Vault role for Tailscale (JWT auth)
  doing "Creating Vault role for Tailscale..."
  curl -sf -X POST "$VAULT_ADDR/v1/auth/jwt-nomad/role/tailscale" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "role_type": "jwt",
      "bound_audiences": ["vault.io"],
      "user_claim": "/nomad_job_id",
      "user_claim_json_pointer": true,
      "claim_mappings": {
        "nomad_namespace": "nomad_namespace",
        "nomad_job_id": "nomad_job_id"
      },
      "token_type": "service",
      "token_policies": ["tailscale"],
      "token_ttl": "1h"
    }' > /dev/null

  # Create per-node state directories and configure each node
  doing "Configuring all Nomad nodes for Tailscale routing..."
  for ip in $ALL_NOMAD_IPS; do
    local hostname
    hostname=$(jq -r --arg ip "$ip" '.external[] | select(.ip | startswith($ip)) | .hostname' hosts.json)

    # Create per-node state directory
    sshRunAdmin "$VM_USER" "$ip" "sudo mkdir -p /srv/gluster/nomad-data/tailscale/$hostname && sudo chmod 755 /srv/gluster/nomad-data/tailscale/$hostname"

    # Enable IP forwarding
    sshRunAdmin "$VM_USER" "$ip" "echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null"
    sshRunAdmin "$VM_USER" "$ip" "echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-tailscale.conf > /dev/null"

    # Add iptables rules
    sshRunAdmin "$VM_USER" "$ip" "sudo iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD 1 -i tailscale0 -j ACCEPT" || true
    sshRunAdmin "$VM_USER" "$ip" "sudo iptables -C FORWARD -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD 2 -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT" || true
    sshRunAdmin "$VM_USER" "$ip" "command -v iptables-legacy >/dev/null && (sudo iptables-legacy -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || sudo iptables-legacy -I FORWARD 1 -i tailscale0 -j ACCEPT) || true"
    sshRunAdmin "$VM_USER" "$ip" "command -v iptables-legacy >/dev/null && (sudo iptables-legacy -C FORWARD -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || sudo iptables-legacy -I FORWARD 2 -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT) || true"

    info "  Configured $hostname ($ip)"
  done

  # Export for envsubst
  export TAILSCALE_SUBNET

  # Deploy using the generic Nomad job deployer
  doing "Deploying Tailscale system job..."

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

  # Wait for containers to start
  doing "Waiting for Tailscale containers to start on all nodes..."
  sleep 10

  # Get DNS server IP for instructions
  local DNS_IP=""
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local DNS_HA_VIP
    DNS_HA_VIP=$(jq -r '.network.external.ha_vip // ""' "$CLUSTER_INFO_FILE" | cut -d'/' -f1)
    if [ -n "$DNS_HA_VIP" ] && [ "$DNS_HA_VIP" != "null" ]; then
      DNS_IP="$DNS_HA_VIP"
    fi
  fi
  if [ -z "$DNS_IP" ]; then
    DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  fi

  echo
  success "Tailscale HA deployment complete!"
  echo
  info "Tailscale is running on all Nomad nodes with auth key from Vault."
  info "Nodes should auto-register with Tailscale (may take 30-60 seconds)."
  echo
  warn "Post-deployment steps:"
  echo
  info "Step 1: Approve subnet routes in Tailscale Admin Console"
  echo "  https://login.tailscale.com/admin/machines"
  echo "  Find each nomad node → Edit route settings → Approve routes"
  echo
  info "Step 2: Configure split DNS for internal domain resolution"
  echo "  https://login.tailscale.com/admin/dns"
  echo "  → Nameservers → Add nameserver → Custom"
  echo "  → Enter: $DNS_IP"
  echo "  → Check 'Restrict to search domain' → Enter: $DNS_POSTFIX"
  echo "  → Save"
  echo
  info "Step 3: On remote Tailscale clients, accept routes"
  echo "  tailscale up --accept-routes"
  echo
  warn "Auth key rotation: Key expires in 90 days. To rotate:"
  echo "  1. Generate new key at https://login.tailscale.com/admin/settings/keys"
  echo "  2. Update Vault: vault kv put secret/tailscale auth_key=tskey-auth-xxxxx"
  echo "  3. Restart Tailscale job: nomad job restart tailscale"
  echo
}

# rotateTailscaleKey - Rotate the Tailscale auth key in Vault
function rotateTailscaleKey() {
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials not found"
    return 1
  fi

  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  echo
  info "Generate a new auth key at: https://login.tailscale.com/admin/settings/keys"
  echo "  → Reusable: YES"
  echo "  → Pre-authorized: YES"
  echo "  → Expiry: 90 days"
  echo
  read -rsp "$(question "Paste your new Tailscale auth key: ")" TS_AUTH_KEY
  echo

  if [ -z "$TS_AUTH_KEY" ]; then
    error "No auth key provided"
    return 1
  fi

  doing "Updating auth key in Vault..."
  if ! curl -sf -X POST "$VAULT_ADDR/v1/secret/data/tailscale" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"data\": {\"auth_key\": \"$TS_AUTH_KEY\"}}" > /dev/null; then
    error "Failed to update auth key in Vault"
    return 1
  fi

  success "Auth key updated in Vault"

  # Get first Nomad node IP
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  doing "Restarting Tailscale job to use new key..."
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "nomad job restart tailscale"

  success "Tailscale auth key rotated successfully!"
}
