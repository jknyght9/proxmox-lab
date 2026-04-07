#!/usr/bin/env bash

# deploySambaADOnly - Deploy Samba AD Domain Controllers as Nomad services
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Critical services deployed (DNS, CA)
#   - Vault deployed and unsealed with Nomad integration configured
#   - GlusterFS mounted at NOMAD_DATA_DIR
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, VAULT_CREDENTIALS_FILE, SCRIPT_DIR,
#               SAMBA_DC01_DIR, SAMBA_DC02_DIR
# Globals set: AD_REALM, AD_DOMAIN (derived from DNS_POSTFIX or user input)
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates Samba DC storage directories on GlusterFS
#   - Stores AD secrets in Vault KV store
#   - Deploys primary DC (provisions new domain)
#   - Deploys replica DC (joins domain)
#   - Updates DNS with AD SRV records
#   - Saves AD config to cluster-info.json
function deploySambaADOnly() {
  cat <<EOF

############################################################################
Samba AD Domain Controllers Deployment

Deploying Samba AD DCs as Nomad services for Active Directory.
Primary DC (DC01) on nomad01, Replica DC (DC02) on nomad02.
Requires: Nomad cluster running, Vault for secrets
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureCriticalServices || return 1
  ensureNomadCluster || return 1

  # Configure AD realm and domain
  configureADRealm || return 1

  # Check Vault is deployed (required for secrets management)
  if ! isVaultDeployed 2>/dev/null; then
    error "Vault is not deployed. Deploy Vault first (option 8)."
    return 1
  fi
  success "Vault is running"

  # Check credentials file exists
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials file not found: $VAULT_CREDENTIALS_FILE"
    info "Deploy Vault first (option 8) to generate credentials."
    return 1
  fi

  # Get Vault connection info
  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ] || [ -z "$ROOT_TOKEN" ]; then
    error "Could not read Vault credentials from $VAULT_CREDENTIALS_FILE"
    return 1
  fi

  # Check if Vault is sealed and unseal if needed
  doing "Checking Vault seal status..."
  if isVaultSealed; then
    warn "Vault is sealed, attempting to unseal..."
    if ! unsealVault; then
      error "Could not unseal Vault. Cannot deploy Samba AD."
      return 1
    fi
  fi
  success "Vault is unsealed"

  # Check if Nomad-Vault integration is configured
  if ! isNomadVaultConfigured 2>/dev/null; then
    error "Nomad-Vault integration is not configured."
    info "Run 'Configure Nomad-Vault integration' to fix this."
    return 1
  fi
  success "Nomad-Vault integration is configured"

  # Get Nomad node IPs from hosts.json
  local NOMAD01_IP NOMAD02_IP
  NOMAD01_IP=$(jq -r '.external[] | select(.hostname == "nomad01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  NOMAD02_IP=$(jq -r '.external[] | select(.hostname == "nomad02") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -z "$NOMAD01_IP" ] || [ "$NOMAD01_IP" = "null" ]; then
    error "Could not find nomad01 IP in hosts.json"
    return 1
  fi

  if [ -z "$NOMAD02_IP" ] || [ "$NOMAD02_IP" = "null" ]; then
    warn "Could not find nomad02 IP - replica DC will not be deployed"
  fi

  # Get DNS forwarder (use dns-01, fallback to external gateway)
  local DNS_FORWARDER
  DNS_FORWARDER=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  if [ -z "$DNS_FORWARDER" ] || [ "$DNS_FORWARDER" = "null" ]; then
    # Fallback to external gateway from cluster-info.json
    DNS_FORWARDER=$(jq -r '.network.external.gateway // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)
    if [ -z "$DNS_FORWARDER" ] || [ "$DNS_FORWARDER" = "null" ]; then
      error "Could not determine DNS forwarder. Deploy dns-01 first or check cluster-info.json"
      return 1
    fi
    warn "dns-01 not found in hosts.json, using gateway as DNS forwarder: $DNS_FORWARDER"
  fi

  # Create Vault policy for samba-dc
  doing "Creating Vault policy for Samba DC..."
  local SAMBA_POLICY
  SAMBA_POLICY=$(cat "$SCRIPT_DIR/nomad/vault-policies/samba-dc.hcl")

  if ! curl -sf --connect-timeout 5 --max-time 10 -X PUT "${VAULT_ADDR}/v1/sys/policies/acl/samba-dc" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"policy\": $(echo "$SAMBA_POLICY" | jq -Rs .)}" > /dev/null; then
    error "Failed to create samba-dc policy"
    return 1
  fi
  success "Created samba-dc policy"

  # Create Vault role for samba-dc
  doing "Creating Vault role for Samba DC workloads..."

  local SAMBA_ROLE
  SAMBA_ROLE=$(cat <<'ROLE_JSON'
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
  "token_policies": ["samba-dc"],
  "token_period": "1h",
  "token_ttl": "1h",
  "bound_claims": {
    "nomad_job_id": "samba-dc"
  }
}
ROLE_JSON
)

  if ! curl -sf -X POST "${VAULT_ADDR}/v1/auth/jwt-nomad/role/samba-dc" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$SAMBA_ROLE" > /dev/null; then
    error "Failed to create samba-dc role"
    return 1
  fi
  success "Created Vault role 'samba-dc'"

  # Check if secrets already exist in Vault
  doing "Checking for existing AD secrets in Vault..."

  local SECRETS_EXIST=false
  local EXISTING_SECRETS
  EXISTING_SECRETS=$(curl -s --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/secret/data/samba-ad" \
    -H "X-Vault-Token: $ROOT_TOKEN" 2>/dev/null || echo "{}")

  if echo "$EXISTING_SECRETS" | jq -e '.data.data.admin_password' >/dev/null 2>&1; then
    SECRETS_EXIST=true
    success "Found existing AD secrets in Vault"
  fi

  if [ "$SECRETS_EXIST" = "false" ]; then
    doing "Generating and storing AD secrets in Vault..."

    # Generate secure passwords
    local ADMIN_PASSWORD SYNC_PASSWORD
    ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '\n' | tr -dc 'a-zA-Z0-9' | head -c 20)
    SYNC_PASSWORD=$(openssl rand -base64 16 | tr -d '\n' | tr -dc 'a-zA-Z0-9' | head -c 20)

    # Build LDAP DN from AD realm (e.g., AD.JDCLABS.LAN -> dc=ad,dc=jdclabs,dc=lan)
    local AD_REALM_LOWER SYNC_BASE_DN
    AD_REALM_LOWER=$(echo "$AD_REALM" | tr '[:upper:]' '[:lower:]')
    # Convert realm to DN format: ad.jdclabs.lan -> dc=ad,dc=jdclabs,dc=lan
    SYNC_BASE_DN=$(echo "$AD_REALM_LOWER" | sed 's/\./,dc=/g' | sed 's/^/dc=/')
    local SYNC_DN="cn=authentik-sync,cn=Users,${SYNC_BASE_DN}"

    # Store secrets in Vault KV v2
    local SECRET_PAYLOAD
    SECRET_PAYLOAD=$(jq -n \
      --arg admin_pass "$ADMIN_PASSWORD" \
      --arg sync_pass "$SYNC_PASSWORD" \
      --arg sync_dn "$SYNC_DN" \
      '{data: {admin_password: $admin_pass, authentik_sync_password: $sync_pass, authentik_sync_dn: $sync_dn}}')

    if ! curl -sf --connect-timeout 5 --max-time 10 -X POST \
      "${VAULT_ADDR}/v1/secret/data/samba-ad" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$SECRET_PAYLOAD" > /dev/null; then
      error "Failed to store AD secrets in Vault"
      return 1
    fi

    success "AD secrets stored in Vault at secret/data/samba-ad"
    info "AD Administrator password saved to Vault (retrieve with: vault kv get secret/samba-ad)"
  fi

  # Create storage directories for DC01 (using local storage, not GlusterFS)
  # Samba AD requires POSIX ACL support which GlusterFS FUSE doesn't provide
  doing "Preparing DC01 local storage directories on nomad01..."

  if ! sshScriptAdmin "$VM_USER" "$NOMAD01_IP" <<'REMOTE_SCRIPT'
    DC01_DIR="/opt/samba-dc01"

    # Clean up any stale data from previous deployments
    if [ -d "$DC01_DIR" ]; then
      echo "Cleaning up previous DC01 data..."
      sudo rm -rf "$DC01_DIR"
    fi

    # Create required directories on local filesystem (supports ACLs)
    sudo mkdir -p "$DC01_DIR"/{samba,krb5}
    sudo chmod -R 755 "$DC01_DIR"

    echo "DC01 local storage directories prepared at $DC01_DIR"
REMOTE_SCRIPT
  then
    error "Failed to prepare DC01 storage"
    return 1
  fi

  # Create storage directories for DC02 (if nomad02 exists)
  if [ -n "$NOMAD02_IP" ] && [ "$NOMAD02_IP" != "null" ]; then
    doing "Preparing DC02 local storage directories on nomad02..."

    if ! sshScriptAdmin "$VM_USER" "$NOMAD02_IP" <<'REMOTE_SCRIPT'
      DC02_DIR="/opt/samba-dc02"

      # Clean up any stale data from previous deployments
      if [ -d "$DC02_DIR" ]; then
        echo "Cleaning up previous DC02 data..."
        sudo rm -rf "$DC02_DIR"
      fi

      # Create required directories on local filesystem (supports ACLs)
      sudo mkdir -p "$DC02_DIR"/{samba,krb5}
      sudo chmod -R 755 "$DC02_DIR"

      echo "DC02 local storage directories prepared at $DC02_DIR"
REMOTE_SCRIPT
    then
      warn "Failed to prepare DC02 storage - continuing with DC01 only"
    fi
  fi

  # Prepare job file with variable substitution
  doing "Preparing Samba DC Nomad job..."

  # Ensure DNS_POSTFIX is loaded
  if [ -z "${DNS_POSTFIX:-}" ] || [ "$DNS_POSTFIX" = "null" ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    fi
  fi

  if [ -z "${DNS_POSTFIX:-}" ] || [ "$DNS_POSTFIX" = "null" ]; then
    error "DNS_POSTFIX not configured. Run initial setup first."
    return 1
  fi

  local AD_REALM_LOWER
  AD_REALM_LOWER=$(echo "$AD_REALM" | tr '[:upper:]' '[:lower:]')

  # Export variables for envsubst
  export AD_REALM AD_DOMAIN DNS_FORWARDER AD_REALM_LOWER DNS_POSTFIX NOMAD01_IP NOMAD02_IP

  # Check if we're deploying single DC or dual DC setup
  local DEPLOY_REPLICA=false
  if [ -n "$NOMAD02_IP" ] && [ "$NOMAD02_IP" != "null" ]; then
    DEPLOY_REPLICA=true
    info "Multi-node cluster detected - deploying dual DC setup"
    info "  DC01 (primary) on nomad01: provisions new domain"
    info "  DC02 (replica) on nomad02: joins existing domain"
    info ""
    info "Sequential deployment: DC01 first, then DC02 (required for fresh provisioning)"
  else
    info "Single node deployment - deploying primary DC only (DC01 on nomad01)"
  fi

  # ==========================================================================
  # Phase 1: Deploy DC01 only (provisions the domain)
  # ==========================================================================
  doing "Phase 1: Deploying DC01 (primary domain controller)..."

  # Generate DC01-only job file
  generateSambaDCJob "false" > "/tmp/samba-dc-rendered.nomad.hcl"

  # Apply variable substitution
  envsubst '${AD_REALM} ${AD_DOMAIN} ${DNS_FORWARDER} ${AD_REALM_LOWER} ${DNS_POSTFIX} ${NOMAD01_IP} ${NOMAD02_IP}' \
    < "/tmp/samba-dc-rendered.nomad.hcl" \
    > "/tmp/samba-dc-final.nomad.hcl"
  mv "/tmp/samba-dc-final.nomad.hcl" "/tmp/samba-dc-rendered.nomad.hcl"

  # Copy to Nomad node
  scpToAdmin "/tmp/samba-dc-rendered.nomad.hcl" "$VM_USER" "$NOMAD01_IP" "/tmp/samba-dc.nomad.hcl"

  # Deploy DC01 only
  if ! sshRunAdmin "$VM_USER" "$NOMAD01_IP" "nomad job run /tmp/samba-dc.nomad.hcl"; then
    error "Failed to deploy DC01"
    rm -f "/tmp/samba-dc-rendered.nomad.hcl"
    return 1
  fi

  # Wait for DC01 to become healthy in Nomad
  doing "Waiting for DC01 to provision AD domain and become healthy..."

  local DC01_HEALTHY=false
  for attempt in {1..60}; do
    # Check Nomad deployment status for dc01 healthy count (4th column in dc01 row)
    local dc01_healthy
    dc01_healthy=$(sshRunAdmin "$VM_USER" "$NOMAD01_IP" "nomad job status samba-dc 2>/dev/null | awk '/^dc01/{print \$4}' | head -1" 2>/dev/null || echo "0")
    if [ "$dc01_healthy" = "1" ]; then
      DC01_HEALTHY=true
      break
    fi
    echo -n "."
    sleep 5
  done
  echo

  if [ "$DC01_HEALTHY" = "false" ]; then
    error "DC01 failed to become healthy within timeout"
    info "Check logs with: nomad alloc logs -job samba-dc"
    sshRunAdmin "$VM_USER" "$NOMAD01_IP" "nomad job status samba-dc | tail -20"
    rm -f "/tmp/samba-dc-rendered.nomad.hcl"
    return 1
  fi
  success "DC01 is healthy and domain is provisioned"

  # ==========================================================================
  # Phase 2: Add DC02 if multi-node setup
  # ==========================================================================
  if [ "$DEPLOY_REPLICA" = "true" ]; then
    doing "Phase 2: Adding DC02 (replica domain controller)..."

    # Generate full job with both DCs
    generateSambaDCJob "true" > "/tmp/samba-dc-rendered.nomad.hcl"

    # Apply variable substitution
    envsubst '${AD_REALM} ${AD_DOMAIN} ${DNS_FORWARDER} ${AD_REALM_LOWER} ${DNS_POSTFIX} ${NOMAD01_IP} ${NOMAD02_IP}' \
      < "/tmp/samba-dc-rendered.nomad.hcl" \
      > "/tmp/samba-dc-final.nomad.hcl"
    mv "/tmp/samba-dc-final.nomad.hcl" "/tmp/samba-dc-rendered.nomad.hcl"

    # Copy updated job to Nomad node
    scpToAdmin "/tmp/samba-dc-rendered.nomad.hcl" "$VM_USER" "$NOMAD01_IP" "/tmp/samba-dc.nomad.hcl"

    # Deploy updated job (adds DC02)
    if ! sshRunAdmin "$VM_USER" "$NOMAD01_IP" "nomad job run /tmp/samba-dc.nomad.hcl"; then
      error "Failed to deploy DC02"
      rm -f "/tmp/samba-dc-rendered.nomad.hcl"
      return 1
    fi

    # Wait for DC02 to become healthy
    doing "Waiting for DC02 to join domain and become healthy..."

    local DC02_HEALTHY=false
    for attempt in {1..60}; do
      # Check Nomad deployment status for dc02 healthy count (4th column in dc02 row)
      local dc02_healthy
      dc02_healthy=$(sshRunAdmin "$VM_USER" "$NOMAD01_IP" "nomad job status samba-dc 2>/dev/null | awk '/^dc02/{print \$4}' | head -1" 2>/dev/null || echo "0")
      if [ "$dc02_healthy" = "1" ]; then
        DC02_HEALTHY=true
        break
      fi
      echo -n "."
      sleep 5
    done
    echo

    if [ "$DC02_HEALTHY" = "false" ]; then
      warn "DC02 did not become healthy within timeout"
      info "DC01 is running - DC02 may still be joining the domain"
      info "Check logs with: nomad alloc logs -job samba-dc"
    else
      success "DC02 is healthy and joined the domain"
    fi
  fi

  # Clean up
  sshRunAdmin "$VM_USER" "$NOMAD01_IP" "rm -f /tmp/samba-dc.nomad.hcl"
  rm -f "/tmp/samba-dc-rendered.nomad.hcl"

  # Show final job status
  doing "Final job status:"
  sshRunAdmin "$VM_USER" "$NOMAD01_IP" "nomad job status samba-dc | head -30"

  # Update DNS records for AD
  updateADDNSRecords

  displayDeploymentSummary

  echo
  info "Samba AD Domain Controller deployed!"
  info "AD Realm: $AD_REALM"
  info "AD Domain (NetBIOS): $AD_DOMAIN"
  info "Primary DC: samba-dc01 ($NOMAD01_IP:389)"
  if [ "$DEPLOY_REPLICA" = "true" ]; then
    info "Replica DC: samba-dc02 ($NOMAD02_IP:389)"
  fi
  echo
  info "AD secrets stored in Vault at: secret/data/samba-ad"
  info "Retrieve admin password: vault kv get secret/samba-ad"
  echo
  info "To join a Windows machine to the domain:"
  info "  1. Set DNS to point to Pi-hole ($DNS_FORWARDER)"
  info "  2. Join domain: $AD_REALM"
  echo
  info "To verify AD is working:"
  info "  samba-tool domain level show"
  if [ "$DEPLOY_REPLICA" = "true" ]; then
    info "  samba-tool drs showrepl  # Check replication status"
  fi

  success "Samba AD deployment complete!"
}

# Check if Samba AD is deployed as a Nomad job
function isSambaADDeployed() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  local status
  status=$(sshRunAdmin "$VM_USER" "$nomad_ip" "nomad job status samba-dc 2>/dev/null | grep -c 'running'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}

# Update DNS records for Active Directory
# Adds SRV records and A records for domain controllers
function updateADDNSRecords() {
  doing "Updating DNS with AD records..."

  # Load configuration from cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    # Load AD config if not already set
    if [ -z "${AD_REALM:-}" ]; then
      AD_REALM=$(jq -r '.ad_config.realm // ""' "$CLUSTER_INFO_FILE")
      AD_DOMAIN=$(jq -r '.ad_config.domain // "AD"' "$CLUSTER_INFO_FILE")
    fi
  fi

  if [ -z "${DNS_POSTFIX}" ]; then
    warn "DNS_POSTFIX not set, skipping AD DNS update"
    return 1
  fi

  if [ -z "${AD_REALM:-}" ] || [ "$AD_REALM" = "null" ]; then
    warn "AD_REALM not configured, skipping AD DNS update"
    return 1
  fi

  # Get DNS server IP
  local DNS_IP
  DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -z "$DNS_IP" ] || [ "$DNS_IP" = "null" ]; then
    warn "Could not find dns-01 IP, skipping AD DNS update"
    return 1
  fi

  # Get DC IPs
  local NOMAD01_IP NOMAD02_IP
  NOMAD01_IP=$(jq -r '.external[] | select(.hostname == "nomad01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  NOMAD02_IP=$(jq -r '.external[] | select(.hostname == "nomad02") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  local AD_REALM_LOWER
  AD_REALM_LOWER=$(echo "$AD_REALM" | tr '[:upper:]' '[:lower:]')

  # Build AD DNS records
  local AD_DNS_RECORDS="[]"

  # A records for domain controllers
  AD_DNS_RECORDS=$(jq -n --arg ip1 "$NOMAD01_IP" --arg realm "$AD_REALM_LOWER" \
    '["\($ip1) samba-dc01 samba-dc01.\($realm)"]')

  if [ -n "$NOMAD02_IP" ] && [ "$NOMAD02_IP" != "null" ]; then
    AD_DNS_RECORDS=$(echo "$AD_DNS_RECORDS" | jq --arg ip2 "$NOMAD02_IP" --arg realm "$AD_REALM_LOWER" \
      '. + ["\($ip2) samba-dc02 samba-dc02.\($realm)"]')
  fi

  info "Adding AD DNS records:"
  echo "$AD_DNS_RECORDS" | jq -r '.[]' | while read -r record; do
    echo "    - $record"
  done

  # Get existing DNS records and merge
  # Pi-hole LXC containers use root user and admin key
  local EXISTING_RECORDS
  EXISTING_RECORDS=$(sshRunAdmin "root" "$DNS_IP" "pihole-FTL --config dns.hosts" 2>/dev/null || echo "")

  # Validate that EXISTING_RECORDS is valid JSON array, default to empty array if not
  if ! echo "$EXISTING_RECORDS" | jq -e 'type == "array"' >/dev/null 2>&1; then
    EXISTING_RECORDS="[]"
  fi

  # Merge records (avoiding duplicates)
  local MERGED_RECORDS
  MERGED_RECORDS=$(echo "{\"existing\": $EXISTING_RECORDS, \"new\": $AD_DNS_RECORDS}" | jq '.existing + .new | unique')

  # Update Pi-hole
  if sshRunAdmin "root" "$DNS_IP" "pihole-FTL --config dns.hosts '$MERGED_RECORDS'"; then
    success "AD DNS records added to Pi-hole"
  else
    warn "Failed to update Pi-hole with AD records"
  fi

  # Configure conditional forwarding for AD domain
  doing "Configuring conditional forwarding for $AD_REALM_LOWER..."

  # Pi-hole v6 uses misc.dnsmasq_lines for custom dnsmasq config
  # Also need to disable dns.domain.local to allow forwarding queries for the local domain
  local FORWARD_CONFIG="server=/${AD_REALM_LOWER}/${NOMAD01_IP}"

  if sshRunAdmin "root" "$DNS_IP" "pihole-FTL --config dns.domain.local false && pihole-FTL --config misc.dnsmasq_lines '[\"$FORWARD_CONFIG\"]' && systemctl restart pihole-FTL"; then
    success "Conditional forwarding configured for $AD_REALM_LOWER"
  else
    warn "Failed to configure conditional forwarding"
  fi

  return 0
}

# configureADRealm - Configure AD realm and domain, either from saved config or user input
#
# Sets global variables: AD_REALM, AD_DOMAIN
# Saves configuration to cluster-info.json for persistence
function configureADRealm() {
  # Load DNS_POSTFIX if not already set
  if [ -z "${DNS_POSTFIX:-}" ] && [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
  fi

  if [ -z "${DNS_POSTFIX:-}" ]; then
    error "DNS_POSTFIX not configured. Run initial setup first."
    return 1
  fi

  # Check for existing AD configuration in cluster-info.json
  local SAVED_AD_REALM SAVED_AD_DOMAIN
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    SAVED_AD_REALM=$(jq -r '.ad_config.realm // ""' "$CLUSTER_INFO_FILE")
    SAVED_AD_DOMAIN=$(jq -r '.ad_config.domain // ""' "$CLUSTER_INFO_FILE")
  fi

  if [ -n "$SAVED_AD_REALM" ] && [ "$SAVED_AD_REALM" != "null" ]; then
    # Use existing configuration
    AD_REALM="$SAVED_AD_REALM"
    AD_DOMAIN="${SAVED_AD_DOMAIN:-AD}"
    info "Using existing AD configuration from cluster-info.json"
    info "  AD Realm: $AD_REALM"
    info "  AD Domain (NetBIOS): $AD_DOMAIN"
    echo

    read -rp "$(question "Use this configuration? [Y/n]: ")" USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}

    if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
      return 0
    fi
  fi

  # Generate defaults from DNS_POSTFIX
  # e.g., DNS_POSTFIX="jdclabs.lan" -> AD_REALM="JDCLABS.LAN", AD_DOMAIN="JDCLABS"
  local DNS_POSTFIX_UPPER DOMAIN_PART
  DNS_POSTFIX_UPPER=$(echo "$DNS_POSTFIX" | tr '[:lower:]' '[:upper:]')
  # Extract first part of domain for NetBIOS name (e.g., "jdclabs" from "jdclabs.lan")
  DOMAIN_PART=$(echo "$DNS_POSTFIX" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]')
  local DEFAULT_REALM="${DNS_POSTFIX_UPPER}"
  # NetBIOS name max 15 chars
  local DEFAULT_DOMAIN="${DOMAIN_PART:0:15}"

  echo
  info "Active Directory Configuration"
  info "==============================="
  info "The AD realm will be used for Kerberos authentication and domain joins."
  info "Default derives from your DNS suffix: $DNS_POSTFIX"
  echo

  # Prompt for AD realm
  read -rp "$(question "Enter AD Realm [$DEFAULT_REALM]: ")" AD_REALM
  AD_REALM=${AD_REALM:-$DEFAULT_REALM}
  # Ensure uppercase
  AD_REALM=$(echo "$AD_REALM" | tr '[:lower:]' '[:upper:]')

  # Prompt for NetBIOS domain name
  read -rp "$(question "Enter NetBIOS Domain Name [$DEFAULT_DOMAIN]: ")" AD_DOMAIN
  AD_DOMAIN=${AD_DOMAIN:-$DEFAULT_DOMAIN}
  # Ensure uppercase and max 15 chars
  AD_DOMAIN=$(echo "$AD_DOMAIN" | tr '[:lower:]' '[:upper:]' | cut -c1-15)

  echo
  info "AD Configuration:"
  info "  AD Realm: $AD_REALM"
  info "  AD Domain (NetBIOS): $AD_DOMAIN"
  echo

  # Save to cluster-info.json
  doing "Saving AD configuration to cluster-info.json..."
  local tmp_file
  tmp_file=$(mktemp)
  jq --arg realm "$AD_REALM" --arg domain "$AD_DOMAIN" \
    '. + {ad_config: {realm: $realm, domain: $domain}}' \
    "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  success "AD configuration saved"

  return 0
}

# getADConfig - Load AD configuration from cluster-info.json
# Sets global variables: AD_REALM, AD_DOMAIN
function getADConfig() {
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    AD_REALM=$(jq -r '.ad_config.realm // ""' "$CLUSTER_INFO_FILE")
    AD_DOMAIN=$(jq -r '.ad_config.domain // "AD"' "$CLUSTER_INFO_FILE")
  fi

  if [ -z "$AD_REALM" ] || [ "$AD_REALM" = "null" ]; then
    return 1
  fi

  return 0
}

# generateSambaDCJob - Generate Samba DC Nomad job file
# Arguments:
#   $1 - "true" to include replica DC, "false" for single DC
# Outputs job file content to stdout
function generateSambaDCJob() {
  local INCLUDE_REPLICA="${1:-false}"

  cat <<'EOF_JOB_START'
job "samba-dc" {
  datacenters = ["dc1"]
  type        = "service"

  # ===========================================================================
  # Primary Domain Controller (DC01) - Provisions new AD domain
  # ===========================================================================
  group "dc01" {
    count = 1

    # Pin to nomad01 for consistent DNS and service discovery
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }

    # Vault integration - fetch secrets at runtime using Workload Identity
    vault {
      role        = "samba-dc"
      change_mode = "noop"  # Don't restart on secret change - AD is stateful
    }

    # Restart policy - handle transient failures during domain provisioning
    restart {
      attempts = 3
      interval = "5m"
      delay    = "30s"
      mode     = "delay"
    }

    network {
      mode = "host"
      # Samba DNS binds to port 53 by default in host network mode
      port "dns"      { static = 53 }
      port "kerberos" { static = 88 }
      port "ldap"     { static = 389 }
      port "ldaps"    { static = 636 }
      port "smb"      { static = 445 }
      port "gc"       { static = 3268 }  # Global Catalog
      port "gcs"      { static = 3269 }  # Global Catalog SSL
    }

    task "samba-dc" {
      driver = "docker"

      # Graceful shutdown for AD replication consistency
      kill_timeout = "120s"

      config {
        image        = "ghcr.io/jknyght9/samba-ad-dc:latest"
        network_mode = "host"
        privileged   = true

        # Use local storage (not GlusterFS) - Samba AD requires POSIX ACL support
        # which GlusterFS FUSE doesn't provide. Each DC stores data locally and
        # replicates via AD replication.
        volumes = [
          "/opt/samba-dc01/samba:/var/lib/samba",
          "/opt/samba-dc01/krb5:/etc/krb5",
        ]
      }

      template {
        data = <<EOH
{{ with secret "secret/data/samba-ad" }}
DOMAINPASS={{ .Data.data.admin_password }}
{{ end }}
DOMAIN=${AD_REALM}
DOMAINNAME=${AD_DOMAIN}
HOSTIP=${NOMAD01_IP}
DNSFORWARDER=${DNS_FORWARDER}
JOIN=false
INSECURELDAP=true
NOCOMPLEXITY=true
EOH
        destination = "secrets/samba.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "samba-dc01"
        port     = "ldap"
        provider = "nomad"

        tags = [
          "dc=primary",
          "realm=${AD_REALM}",
        ]

        check {
          type     = "tcp"
          port     = "ldap"
          interval = "30s"
          timeout  = "5s"
        }
      }

      service {
        name     = "samba-dc01-kerberos"
        port     = "kerberos"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "kerberos"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
EOF_JOB_START

  # Only include DC02 group if deploying replica
  if [ "$INCLUDE_REPLICA" = "true" ]; then
    cat <<'EOF_DC02'

  # ===========================================================================
  # Replica Domain Controller (DC02) - Joins existing domain
  # ===========================================================================
  group "dc02" {
    count = 1

    # Pin to nomad02 for HA - different node than DC01
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad02"
    }

    # Vault integration - fetch secrets at runtime using Workload Identity
    vault {
      role        = "samba-dc"
      change_mode = "noop"  # Don't restart on secret change - AD is stateful
    }

    # Restart policy - handle transient failures during domain join
    restart {
      attempts = 3
      interval = "5m"
      delay    = "30s"
      mode     = "delay"
    }

    network {
      mode = "host"
      # Samba DNS binds to port 53 by default in host network mode
      port "dns"      { static = 53 }
      port "kerberos" { static = 88 }
      port "ldap"     { static = 389 }
      port "ldaps"    { static = 636 }
      port "smb"      { static = 445 }
      port "gc"       { static = 3268 }
      port "gcs"      { static = 3269 }
    }

    task "samba-dc" {
      driver = "docker"

      # Graceful shutdown for AD replication consistency
      kill_timeout = "120s"

      config {
        image        = "ghcr.io/jknyght9/samba-ad-dc:latest"
        network_mode = "host"
        privileged   = true

        # Use local storage (not GlusterFS) - Samba AD requires POSIX ACL support
        volumes = [
          "/opt/samba-dc02/samba:/var/lib/samba",
          "/opt/samba-dc02/krb5:/etc/krb5",
        ]
      }

      template {
        data = <<EOH
{{ with secret "secret/data/samba-ad" }}
DOMAINPASS={{ .Data.data.admin_password }}
{{ end }}
DOMAIN=${AD_REALM}
DOMAINNAME=${AD_DOMAIN}
HOSTIP=${NOMAD02_IP}
DNSFORWARDER=${NOMAD01_IP}
DCIP=${NOMAD01_IP}
JOIN=true
JOINSITE=Default-First-Site-Name
INSECURELDAP=true
NOCOMPLEXITY=true
EOH
        destination = "secrets/samba.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "samba-dc02"
        port     = "ldap"
        provider = "nomad"

        tags = [
          "dc=replica",
          "realm=${AD_REALM}",
        ]

        check {
          type     = "tcp"
          port     = "ldap"
          interval = "30s"
          timeout  = "5s"
        }
      }

      service {
        name     = "samba-dc02-kerberos"
        port     = "kerberos"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "kerberos"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
EOF_DC02
  fi

  # Close the job
  echo "}"
}
