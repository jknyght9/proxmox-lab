#!/usr/bin/env bash

# configureTrueNAS.sh - Join TrueNAS SCALE to Active Directory and configure profile shares
#
# Prerequisites:
#   - Samba AD deployed and running
#   - Vault containing AD credentials
#   - TrueNAS SCALE accessible on the network
#   - sshpass installed locally
#
# Globals read: ENTERPRISE_KEY_PATH, ENTERPRISE_PUBKEY_PATH, VAULT_CREDENTIALS_FILE,
#               CLUSTER_INFO_FILE, SCRIPT_DIR

TRUENAS_USER="truenas_admin"
TRUENAS_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# joinTrueNASToAD - Join TrueNAS SCALE to the Samba AD domain
#
# Flow:
#   1. Prompt for TrueNAS IP and password
#   2. Install enterprise SSH key for future passwordless access
#   3. Fetch domain-join credentials from Vault
#   4. Join TrueNAS to AD via midclt
#   5. Configure SMB profile share with AD permissions
#   6. Save TrueNAS config to cluster-info.json
#
# Returns: 0 on success, 1 on failure
function joinTrueNASToAD() {
  cat <<EOF

############################################################################
TrueNAS Active Directory Join

Joins TrueNAS SCALE to the Active Directory domain and configures
an SMB share for user profiles.
#############################################################################

EOF

  # Verify prerequisites
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials not found: $VAULT_CREDENTIALS_FILE"
    error "Deploy Vault and Samba AD first."
    return 1
  fi

  if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    error "Cluster info not found: $CLUSTER_INFO_FILE"
    return 1
  fi

  local AD_REALM AD_DOMAIN
  AD_REALM=$(jq -r '.ad_config.realm // empty' "$CLUSTER_INFO_FILE")
  AD_DOMAIN=$(jq -r '.ad_config.domain // empty' "$CLUSTER_INFO_FILE")

  if [ -z "$AD_REALM" ] || [ -z "$AD_DOMAIN" ]; then
    error "AD configuration not found in cluster-info.json. Deploy Samba AD first."
    return 1
  fi

  info "AD Realm: $AD_REALM"
  info "AD Domain: $AD_DOMAIN"

  # ==========================================================================
  # Step 1: Get TrueNAS connection details
  # ==========================================================================

  # Check if TrueNAS IP is already saved
  local TRUENAS_IP
  TRUENAS_IP=$(jq -r '.truenas.ip // empty' "$CLUSTER_INFO_FILE" 2>/dev/null)

  if [ -n "$TRUENAS_IP" ]; then
    info "Found saved TrueNAS IP: $TRUENAS_IP"
    question "Use this IP? (Y/n): "
    read -r USE_SAVED
    if [[ "$USE_SAVED" =~ ^[nN] ]]; then
      TRUENAS_IP=""
    fi
  fi

  if [ -z "$TRUENAS_IP" ]; then
    question "Enter TrueNAS IP address: "
    read -r TRUENAS_IP
    if [ -z "$TRUENAS_IP" ]; then
      error "TrueNAS IP is required"
      return 1
    fi
  fi

  # Verify TrueNAS is reachable
  doing "Checking connectivity to TrueNAS at $TRUENAS_IP..."
  if ! ping -c 1 -W 3 "$TRUENAS_IP" > /dev/null 2>&1; then
    error "Cannot reach TrueNAS at $TRUENAS_IP"
    return 1
  fi
  success "TrueNAS is reachable"

  # ==========================================================================
  # Step 2: Install SSH key on TrueNAS
  # ==========================================================================

  installTrueNASSSHKey "$TRUENAS_IP" || return 1

  # ==========================================================================
  # Step 3: Fetch domain-join credentials from Vault
  # ==========================================================================

  doing "Fetching domain-join credentials from Vault..."

  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  local SECRETS_JSON
  SECRETS_JSON=$(curl -skf --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/secret/data/samba-ad" \
    -H "X-Vault-Token: $ROOT_TOKEN" 2>/dev/null || echo "{}")

  local DOMAIN_JOIN_PASSWORD
  DOMAIN_JOIN_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.data.data.domain_join_password // empty')

  if [ -z "$DOMAIN_JOIN_PASSWORD" ]; then
    error "Could not retrieve domain_join_password from Vault"
    return 1
  fi
  success "Retrieved domain-join credentials from Vault"

  # ==========================================================================
  # Step 4: Join TrueNAS to AD
  # ==========================================================================

  local AD_REALM_LOWER
  AD_REALM_LOWER=$(echo "$AD_REALM" | tr '[:upper:]' '[:lower:]')

  doing "Checking if TrueNAS is already domain-joined..."

  local AD_STATUS
  AD_STATUS=$(ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
    "${TRUENAS_USER}@${TRUENAS_IP}" \
    "sudo midclt call activedirectory.config 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"enable\", False))' 2>/dev/null" 2>/dev/null) || AD_STATUS="False"

  if [ "$AD_STATUS" = "True" ]; then
    info "TrueNAS is already joined to an AD domain"
    question "Re-join to $AD_REALM_LOWER? (y/N): "
    read -r REJOIN
    if [[ ! "$REJOIN" =~ ^[yY] ]]; then
      info "Skipping AD join"
      # Still proceed to share configuration
      configureTrueNASProfileShare "$TRUENAS_IP" "$AD_REALM_LOWER"
      saveTrueNASConfig "$TRUENAS_IP"
      return 0
    fi
  fi

  doing "Joining TrueNAS to AD domain: $AD_REALM_LOWER..."

  # Configure DNS on TrueNAS to use Pi-hole (required for AD resolution)
  local DNS_IP
  DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -n "$DNS_IP" ]; then
    doing "Configuring TrueNAS DNS to use Pi-hole ($DNS_IP)..."
    # TrueNAS SCALE network.configuration.update expects JSON with the update payload
    if ! ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
      "${TRUENAS_USER}@${TRUENAS_IP}" \
      "sudo midclt call network.configuration.update '{\"nameserver1\": \"${DNS_IP}\"}'" > /dev/null 2>&1; then
      warn "Could not update DNS via midclt."
      warn "Set DNS manually: TrueNAS UI → Network → Global Configuration → Nameserver 1 → ${DNS_IP}"
      question "Continue with AD join? DNS must resolve $AD_REALM_LOWER first. (Y/n): "
      read -r CONTINUE_JOIN
      if [[ "$CONTINUE_JOIN" =~ ^[nN] ]]; then
        info "Set DNS in TrueNAS UI, then re-run this option."
        return 1
      fi
    else
      success "TrueNAS DNS configured to use Pi-hole"
    fi
  fi

  # Join AD domain using domain-join-svc account
  doing "Sending AD join request to TrueNAS..."

  local JOIN_RESULT
  JOIN_RESULT=$(ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
    "${TRUENAS_USER}@${TRUENAS_IP}" \
    "sudo midclt call activedirectory.update '{\"domainname\": \"${AD_REALM_LOWER}\", \"bindname\": \"domain-join-svc\", \"bindpw\": \"${DOMAIN_JOIN_PASSWORD}\", \"enable\": true}'" 2>&1) || true

  if [ -z "$JOIN_RESULT" ] || echo "$JOIN_RESULT" | grep -qi "error"; then
    error "Failed to initiate AD join"
    [ -n "$JOIN_RESULT" ] && error "$JOIN_RESULT"
    return 1
  fi

  # Wait for AD join to complete
  doing "Waiting for AD join to complete..."
  local MAX_WAIT=60
  local WAITED=0
  while [ $WAITED -lt $MAX_WAIT ]; do
    local STARTED
    STARTED=$(ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
      "${TRUENAS_USER}@${TRUENAS_IP}" \
      "sudo midclt call activedirectory.started 2>/dev/null" 2>/dev/null || echo "false")

    if [ "$STARTED" = "true" ]; then
      break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    doing "  Still waiting... (${WAITED}s / ${MAX_WAIT}s)"
  done

  if [ $WAITED -ge $MAX_WAIT ]; then
    error "AD join timed out after ${MAX_WAIT}s"
    error "Check TrueNAS UI for join status and errors"
    return 1
  fi

  success "TrueNAS joined to AD domain: $AD_REALM_LOWER"

  # Verify join
  doing "Verifying AD join..."
  local DOMAIN_INFO
  DOMAIN_INFO=$(ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
    "${TRUENAS_USER}@${TRUENAS_IP}" \
    "sudo midclt call activedirectory.domain_info" 2>/dev/null || echo "{}")

  info "Domain info: $DOMAIN_INFO"

  # ==========================================================================
  # Step 5: Configure profile share
  # ==========================================================================

  configureTrueNASProfileShare "$TRUENAS_IP" "$AD_REALM_LOWER"

  # ==========================================================================
  # Step 6: Save config
  # ==========================================================================

  saveTrueNASConfig "$TRUENAS_IP"

  echo
  success "TrueNAS AD join and profile share configuration complete!"
  echo
  info "TrueNAS: $TRUENAS_IP"
  info "AD Domain: $AD_REALM_LOWER"
  info "Profile Share: \\\\$(hostname -f 2>/dev/null || echo "$TRUENAS_IP")\\profiles"
  echo
}

# installTrueNASSSHKey - Install enterprise SSH key on TrueNAS
#
# Prompts for truenas_admin password, then copies the enterprise public key
# to TrueNAS so subsequent operations use key-based auth.
#
# Arguments: $1 - TrueNAS IP
# Returns: 0 on success, 1 on failure
function installTrueNASSSHKey() {
  local TRUENAS_IP="$1"

  # Check if key auth already works
  doing "Checking if SSH key auth is already configured..."
  if ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
    -o PasswordAuthentication=no -o BatchMode=yes \
    "${TRUENAS_USER}@${TRUENAS_IP}" "echo ok" > /dev/null 2>&1; then
    success "SSH key auth already working for $TRUENAS_USER@$TRUENAS_IP"
    return 0
  fi

  info "SSH key auth not configured. Installing enterprise key on TrueNAS..."
  question "Enter password for $TRUENAS_USER@$TRUENAS_IP: "
  read -rs TRUENAS_PASS
  echo

  if [ -z "$TRUENAS_PASS" ]; then
    error "Password is required"
    return 1
  fi

  # Test password auth
  if ! sshpass -p "$TRUENAS_PASS" ssh $TRUENAS_SSH_OPTS \
    "${TRUENAS_USER}@${TRUENAS_IP}" "echo ok" > /dev/null 2>&1; then
    error "Password authentication failed for $TRUENAS_USER@$TRUENAS_IP"
    return 1
  fi

  # Install enterprise public key
  local PUBKEY_CONTENT
  PUBKEY_CONTENT=$(cat "$ENTERPRISE_PUBKEY_PATH")

  sshpass -p "$TRUENAS_PASS" ssh $TRUENAS_SSH_OPTS \
    "${TRUENAS_USER}@${TRUENAS_IP}" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
     grep -qF '${PUBKEY_CONTENT}' ~/.ssh/authorized_keys 2>/dev/null || \
     (echo '${PUBKEY_CONTENT}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)"

  if [ $? -ne 0 ]; then
    error "Failed to install SSH key on TrueNAS"
    return 1
  fi

  # Verify key auth now works
  if ! ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
    -o PasswordAuthentication=no -o BatchMode=yes \
    "${TRUENAS_USER}@${TRUENAS_IP}" "echo ok" > /dev/null 2>&1; then
    error "SSH key was installed but key auth still fails"
    return 1
  fi

  success "Enterprise SSH key installed on TrueNAS"
  return 0
}

# configureTrueNASProfileShare - Configure SMB share for user profiles
#
# Creates or updates an SMB share on TrueNAS for roaming user profiles.
# The share is configured with AD group permissions.
#
# Arguments: $1 - TrueNAS IP, $2 - AD realm (lowercase)
# Returns: 0 on success (non-fatal on failure)
function configureTrueNASProfileShare() {
  local TRUENAS_IP="$1"
  local AD_REALM_LOWER="$2"

  doing "Configuring SMB profile share on TrueNAS..."

  # Check if profiles share already exists
  local SHARE_EXISTS
  SHARE_EXISTS=$(ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
    "${TRUENAS_USER}@${TRUENAS_IP}" \
    "sudo midclt call sharing.smb.query '[[\"name\", \"=\", \"profiles\"]]' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"true\" if d else \"false\")' 2>/dev/null" 2>/dev/null) || SHARE_EXISTS="false"

  if [ "$SHARE_EXISTS" = "true" ]; then
    info "SMB share 'profiles' already exists"
    question "Reconfigure share with AD permissions? (y/N): "
    read -r RECONFIG
    if [[ ! "$RECONFIG" =~ ^[yY] ]]; then
      info "Skipping share configuration"
      return 0
    fi
  fi

  # Prompt for dataset path (with sensible default)
  local DEFAULT_DATASET="/mnt/pool/profiles"
  question "Enter TrueNAS dataset path for profiles [$DEFAULT_DATASET]: "
  read -r DATASET_PATH
  DATASET_PATH="${DATASET_PATH:-$DEFAULT_DATASET}"

  # Prompt for AD group that gets access (with sensible default)
  local DEFAULT_GROUP="Domain Users"
  question "Enter AD group for profile access [$DEFAULT_GROUP]: "
  read -r AD_GROUP
  AD_GROUP="${AD_GROUP:-$DEFAULT_GROUP}"

  # Verify dataset exists on TrueNAS
  doing "Verifying dataset path exists..."
  if ! ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
    "${TRUENAS_USER}@${TRUENAS_IP}" \
    "[ -d '$DATASET_PATH' ]" 2>/dev/null; then
    warn "Dataset path $DATASET_PATH does not exist on TrueNAS"
    question "Create it? (Y/n): "
    read -r CREATE_DS
    if [[ ! "$CREATE_DS" =~ ^[nN] ]]; then
      ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
        "${TRUENAS_USER}@${TRUENAS_IP}" \
        "sudo mkdir -p '$DATASET_PATH'" 2>/dev/null || {
          warn "Could not create directory — create the dataset manually in TrueNAS UI"
          return 0
        }
      success "Created $DATASET_PATH"
    else
      warn "Skipping share creation — create the dataset first"
      return 0
    fi
  fi

  # Create or update SMB share
  if [ "$SHARE_EXISTS" = "true" ]; then
    doing "Updating existing 'profiles' SMB share..."
    ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
      "${TRUENAS_USER}@${TRUENAS_IP}" "
      SHARE_ID=\$(sudo midclt call sharing.smb.query '[[\"name\", \"=\", \"profiles\"]]' | python3 -c \"import sys,json; print(json.load(sys.stdin)[0]['id'])\")
      sudo midclt call sharing.smb.update \$SHARE_ID '{
        \"path\": \"${DATASET_PATH}\",
        \"purpose\": \"NO_PRESET\",
        \"comment\": \"User profile storage (AD-integrated)\"
      }'
    " > /dev/null 2>&1
  else
    doing "Creating 'profiles' SMB share..."
    ssh -i "$ENTERPRISE_KEY_PATH" $TRUENAS_SSH_OPTS \
      "${TRUENAS_USER}@${TRUENAS_IP}" "
      sudo midclt call sharing.smb.create '{
        \"name\": \"profiles\",
        \"path\": \"${DATASET_PATH}\",
        \"purpose\": \"NO_PRESET\",
        \"comment\": \"User profile storage (AD-integrated)\",
        \"browsable\": true,
        \"ro\": false,
        \"guestok\": false,
        \"abe\": true
      }'
    " > /dev/null 2>&1
  fi

  if [ $? -ne 0 ]; then
    warn "SMB share configuration may have failed — verify in TrueNAS UI"
    return 0
  fi

  success "SMB 'profiles' share configured at $DATASET_PATH"
  info "  AD Group: $AD_GROUP"
  info "  Access-based enumeration: enabled"
  info "  Guest access: disabled"
  echo
  info "Set filesystem ACLs in TrueNAS UI:"
  info "  Storage -> Pools -> $DATASET_PATH -> Edit Permissions"
  info "  Owner Group: $AD_GROUP"
  info "  Apply ACL recursively"

  return 0
}

# saveTrueNASConfig - Save TrueNAS connection info to cluster-info.json
#
# Arguments: $1 - TrueNAS IP
function saveTrueNASConfig() {
  local TRUENAS_IP="$1"

  doing "Saving TrueNAS configuration to cluster-info.json..."

  local UPDATED
  UPDATED=$(jq \
    --arg ip "$TRUENAS_IP" \
    --arg user "$TRUENAS_USER" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.truenas = {ip: $ip, user: $user, joined_at: $ts}' \
    "$CLUSTER_INFO_FILE")

  echo "$UPDATED" > "$CLUSTER_INFO_FILE"
  success "TrueNAS config saved to cluster-info.json"
}
