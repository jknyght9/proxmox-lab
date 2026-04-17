#!/usr/bin/env bash

# deployLAMOnly - Deploy LDAP Account Manager for Samba AD user management
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Samba AD deployed and running
#   - Traefik deployed for routing
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, CLUSTER_INFO_FILE
# Arguments: None
# Returns: 0 on success, 1 on failure
function deployLAMOnly() {
  ensureClusterContext || return 1

  cat <<EOF

############################################################################
LDAP Account Manager (LAM) Deployment

Deploying LAM for web-based Samba AD user management.
Accessible at: https://lam.${DNS_POSTFIX}
Protected by Authentik forward auth.
#############################################################################

EOF

  ensureNomadCluster || return 1

  # Load AD configuration
  if ! getADConfig 2>/dev/null; then
    error "AD configuration not found. Deploy Samba AD first."
    return 1
  fi

  # Check Samba AD is deployed
  if ! isSambaADDeployed 2>/dev/null; then
    error "Samba AD is not deployed. Deploy Samba AD first."
    return 1
  fi
  success "Samba AD is running"

  # Get Nomad node IPs
  local NOMAD01_IP
  NOMAD01_IP=$(jq -r '.external[] | select(.hostname == "nomad01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -z "$NOMAD01_IP" ]; then
    error "Could not find nomad01 IP"
    return 1
  fi

  # Get DNS server
  local DNS_SERVER
  DNS_SERVER=$(jq -r '.network.external.ha_vip // ""' "$CLUSTER_INFO_FILE" 2>/dev/null | cut -d'/' -f1)
  if [ -z "$DNS_SERVER" ] || [ "$DNS_SERVER" = "null" ]; then
    DNS_SERVER=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  fi
  if [ -z "$DNS_SERVER" ]; then
    DNS_SERVER="10.10.0.3"
  fi

  # Build base DN from realm
  local AD_REALM_LOWER BASE_DN
  AD_REALM_LOWER=$(echo "$AD_REALM" | tr '[:upper:]' '[:lower:]')
  BASE_DN=$(echo "$AD_REALM_LOWER" | sed 's/\./,dc=/g' | sed 's/^/dc=/')

  # Create storage directories and bootstrap default config
  doing "Creating LAM storage directories..."
  sshRunAdmin "$VM_USER" "$NOMAD01_IP" "sudo mkdir -p /srv/gluster/nomad-data/lam/{config,session} && sudo chmod -R 777 /srv/gluster/nomad-data/lam"

  # Check if config already exists, if not bootstrap from container defaults
  doing "Bootstrapping LAM default configuration..."
  sshRunAdmin "$VM_USER" "$NOMAD01_IP" bash <<'BOOTSTRAP'
    if [ ! -f /srv/gluster/nomad-data/lam/config/config.cfg ]; then
      echo "Extracting default LAM config from container..."
      docker pull ghcr.io/ldapaccountmanager/lam:stable
      # Create temp container and copy defaults
      docker create --name lam-temp ghcr.io/ldapaccountmanager/lam:stable
      docker cp lam-temp:/etc/ldap-account-manager/. /srv/gluster/nomad-data/lam/config/
      docker rm lam-temp
      chmod -R 777 /srv/gluster/nomad-data/lam/config
      echo "Default config extracted"
    else
      echo "LAM config already exists, skipping bootstrap"
    fi
BOOTSTRAP

  # Create Vault policy and role for LAM
  doing "Configuring Vault policy and role for LAM..."
  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  # Create policy
  local POLICY_HCL
  POLICY_HCL=$(cat "$SCRIPT_DIR/nomad/vault-policies/lam.hcl")
  curl -skf -X PUT "${VAULT_ADDR}/v1/sys/policies/acl/lam" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -d "{\"policy\": $(echo "$POLICY_HCL" | jq -Rs .)}" >/dev/null
  success "Created lam policy"

  # Create role
  curl -skf -X POST "${VAULT_ADDR}/v1/auth/jwt-nomad/role/lam" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -d '{
      "role_type": "jwt",
      "bound_audiences": ["vault.io"],
      "user_claim": "/nomad_job_id",
      "user_claim_json_pointer": true,
      "claim_mappings": {"nomad_namespace": "nomad_namespace", "nomad_job_id": "nomad_job_id"},
      "token_type": "service",
      "token_policies": ["lam"],
      "token_period": 1800,
      "bound_claims": {"nomad_namespace": "default", "nomad_job_id": "lam"}
    }' >/dev/null
  success "Created Vault role 'lam'"

  # Deploy LAM — AD config comes from Vault KV templates, dns_postfix via -var
  doing "Deploying LAM..."
  scpToAdmin "nomad/jobs/lam.nomad.hcl" "$VM_USER" "$NOMAD01_IP" "/tmp/lam.nomad.hcl"

  if ! sshRunAdmin "$VM_USER" "$NOMAD01_IP" "nomad job run -var dns_postfix=${DNS_POSTFIX} /tmp/lam.nomad.hcl"; then
    error "Failed to deploy LAM"
    return 1
  fi

  # Wait for deployment
  doing "Waiting for LAM to start..."
  sleep 10

  # Update DNS records
  doing "Adding LAM DNS record..."
  updateDNSRecords

  echo
  success "LAM deployed successfully!"
  echo
  info "Access LAM at: https://lam.${DNS_POSTFIX}"
  echo
  warn "First-time setup:"
  echo "  1. Log into https://lam.${DNS_POSTFIX}"
  echo "  2. Click 'LAM configuration' (top right)"
  echo "  3. Default password: 'lam'"
  echo "  4. Configure LDAP connection:"
  echo "     - Server: ldaps://${NOMAD01_IP}"
  echo "     - Base DN: ${BASE_DN}"
  echo "     - Admin DN: CN=Administrator,CN=Users,${BASE_DN}"
  echo "  5. Create a server profile for Samba 4"
  echo "  6. Change the config password!"
  echo
}
