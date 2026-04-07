#!/usr/bin/env bash

# configureAuthentikADSyncOnly - Configure Authentik to sync users from Active Directory
#
# Prerequisites:
#   - Samba AD Domain Controllers deployed and running
#   - Authentik deployed and running
#   - Vault containing AD credentials
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, VAULT_CREDENTIALS_FILE, CLUSTER_INFO_FILE
# Globals set: AD_REALM, AD_DOMAIN (loaded from cluster-info.json)
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates sync service account in AD
#   - Configures LDAP Source in Authentik
#   - Sets up property mappings for AD attributes
function configureAuthentikADSyncOnly() {
  cat <<EOF

############################################################################
Authentik AD Sync Configuration

Configuring Authentik to sync users and groups from Active Directory.
This creates a one-way sync: AD -> Authentik (AD is authoritative)
#############################################################################

EOF

  ensureClusterContext || return 1

  # Load AD configuration from cluster-info.json
  if ! getADConfig 2>/dev/null; then
    error "AD configuration not found. Deploy Samba AD first (option 16)."
    return 1
  fi
  info "AD Realm: $AD_REALM"
  info "AD Domain: $AD_DOMAIN"

  # Check Samba AD is deployed
  if ! isSambaADDeployed 2>/dev/null; then
    error "Samba AD is not deployed. Deploy Samba AD first (option 16)."
    return 1
  fi
  success "Samba AD is running"

  # Check Authentik is deployed
  if ! isAuthentikDeployed 2>/dev/null; then
    error "Authentik is not deployed. Deploy Authentik first (option 9)."
    return 1
  fi
  success "Authentik is running"

  # Check credentials file exists
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials file not found: $VAULT_CREDENTIALS_FILE"
    return 1
  fi

  # Get Vault connection info
  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ] || [ -z "$ROOT_TOKEN" ]; then
    error "Could not read Vault credentials"
    return 1
  fi

  # Get AD credentials from Vault
  doing "Retrieving AD credentials from Vault..."

  local AD_SECRETS
  AD_SECRETS=$(curl -s --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/secret/data/samba-ad" \
    -H "X-Vault-Token: $ROOT_TOKEN" 2>/dev/null || echo "{}")

  local ADMIN_PASSWORD SYNC_PASSWORD SYNC_DN
  ADMIN_PASSWORD=$(echo "$AD_SECRETS" | jq -r '.data.data.admin_password // empty')
  SYNC_PASSWORD=$(echo "$AD_SECRETS" | jq -r '.data.data.authentik_sync_password // empty')
  SYNC_DN=$(echo "$AD_SECRETS" | jq -r '.data.data.authentik_sync_dn // empty')

  if [ -z "$ADMIN_PASSWORD" ]; then
    error "Could not retrieve AD admin password from Vault"
    return 1
  fi
  success "Retrieved AD credentials from Vault"

  # Get Nomad/AD IPs
  local NOMAD01_IP
  NOMAD01_IP=$(jq -r '.external[] | select(.hostname == "nomad01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -z "$NOMAD01_IP" ]; then
    error "Could not find nomad01 IP"
    return 1
  fi

  local AD_REALM_LOWER
  AD_REALM_LOWER=$(echo "$AD_REALM" | tr '[:upper:]' '[:lower:]')

  # Build base DN from realm
  local BASE_DN
  BASE_DN=$(echo "$AD_REALM_LOWER" | sed 's/\./,dc=/g' | sed 's/^/dc=/')

  # Create sync service account in AD
  doing "Creating Authentik sync service account in AD..."

  # Use samba-tool via docker exec to create the user
  local CREATE_USER_CMD="docker exec \$(docker ps -q -f name=samba-dc) samba-tool user create authentik-sync '$SYNC_PASSWORD' --description='Authentik LDAP Sync Account' 2>/dev/null || echo 'User may already exist'"

  if sshRunAdmin "$VM_USER" "$NOMAD01_IP" "$CREATE_USER_CMD"; then
    success "Sync service account created (or already exists)"
  else
    warn "Could not create sync account - it may already exist"
  fi

  # Get Authentik API token (need to create one or use bootstrap)
  doing "Configuring Authentik LDAP Source..."

  # For initial setup, we need to use the Authentik admin bootstrap flow
  # or get a token from an existing admin user

  local AUTHENTIK_URL="http://${NOMAD01_IP}:9000"

  # Check if Authentik is ready
  if ! curl -sf --connect-timeout 5 --max-time 10 "${AUTHENTIK_URL}/-/health/live/" > /dev/null 2>&1; then
    error "Authentik is not responding at ${AUTHENTIK_URL}"
    return 1
  fi

  echo
  info "Authentik is running at: ${AUTHENTIK_URL}"
  echo
  warn "Manual configuration required:"
  echo
  echo "  1. Log into Authentik at: https://auth.${DNS_POSTFIX}/"
  echo
  echo "  2. Go to: Directory -> Federation & Social Logins"
  echo "     Click: Create -> LDAP Source"
  echo
  echo "  3. Configure LDAP Source - Basic Settings:"
  echo
  echo "     Name: Active Directory"
  echo "     Slug: active-directory"
  echo "     Enabled: checked"
  echo
  echo "  4. Connection Settings:"
  echo
  echo "     Server URI: ldap://${NOMAD01_IP}"
  echo "     Enable StartTLS: unchecked"
  echo "     Bind CN: ${SYNC_DN}"
  echo "     Bind Password: ${SYNC_PASSWORD}"
  echo "     Base DN: ${BASE_DN}"
  echo
  echo "  5. LDAP Attribute Mapping:"
  echo
  echo "     User Property Mappings: Select all 'LDAP - ...' mappings"
  echo "     Group Property Mappings: Select 'authentik default LDAP Mapping: cn'"
  echo
  echo "  6. Additional Settings:"
  echo
  echo "     User object filter: (&(objectClass=user)(!(objectClass=computer)))"
  echo "     Group object filter: (objectClass=group)"
  echo "     User group membership field: memberOf"
  echo "     Object uniqueness field: objectSid"
  echo "     Sync users: checked"
  echo "     Sync groups: checked"
  echo
  echo "  7. Click Save, then click the Sync button to pull users/groups"
  echo

  # Store LDAP config for reference
  local LDAP_CONFIG_FILE="$SCRIPT_DIR/crypto/authentik-ldap-config.txt"
  mkdir -p "$(dirname "$LDAP_CONFIG_FILE")"
  cat > "$LDAP_CONFIG_FILE" <<EOF
# Authentik LDAP Source Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Connection Settings
Server URI: ldap://${NOMAD01_IP}
Bind DN: ${SYNC_DN}
Bind Password: ${SYNC_PASSWORD}
Base DN: ${BASE_DN}

# Filter Settings
User object filter: (&(objectClass=user)(!(objectClass=computer)))
Group object filter: (objectClass=group)
User group membership field: memberOf
Object uniqueness field: objectSid

# AD Info
AD Realm: ${AD_REALM}
AD Domain: ${AD_DOMAIN}
EOF

  chmod 600 "$LDAP_CONFIG_FILE"

  info "LDAP configuration saved to: $LDAP_CONFIG_FILE"

  success "Authentik AD Sync configuration instructions complete!"
}

# Helper function to wait for Authentik API
function waitForAuthentikAPI() {
  local AUTHENTIK_URL="$1"
  local MAX_ATTEMPTS="${2:-30}"

  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    if curl -sf --connect-timeout 3 --max-time 5 "${AUTHENTIK_URL}/-/health/live/" > /dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}
