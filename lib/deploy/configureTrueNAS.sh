#!/usr/bin/env bash

# configureTrueNAS.sh - Join TrueNAS SCALE to Active Directory and configure profile shares
#
# Uses the TrueNAS REST API (v2.0) over HTTPS — no SSH or sudo required.
# An API key is generated in TrueNAS UI and stored in Vault for reuse.
#
# Prerequisites:
#   - Samba AD deployed and running
#   - Vault containing AD credentials
#   - TrueNAS SCALE accessible on the network
#   - TrueNAS API key (generated in UI: top-right user → API Keys)
#
# Globals read: VAULT_CREDENTIALS_FILE, CLUSTER_INFO_FILE, SCRIPT_DIR

# truenasAPI - Make authenticated REST API call to TrueNAS
#
# Arguments: $1 - HTTP method, $2 - API endpoint path, $3 - JSON body (optional)
# Globals read: TRUENAS_IP, TRUENAS_API_KEY
# Returns: curl output (JSON)
function truenasAPI() {
  local METHOD="$1"
  local ENDPOINT="$2"
  local BODY="${3:-}"

  local CURL_ARGS=(
    -sk
    --connect-timeout 10
    --max-time 30
    -X "$METHOD"
    -H "Authorization: Bearer ${TRUENAS_API_KEY}"
    -H "Content-Type: application/json"
    "https://${TRUENAS_IP}/api/v2.0${ENDPOINT}"
  )

  if [ -n "$BODY" ]; then
    CURL_ARGS+=(-d "$BODY")
  fi

  curl "${CURL_ARGS[@]}" 2>/dev/null
}

# joinTrueNASToAD - Join TrueNAS SCALE to the Samba AD domain
#
# Flow:
#   1. Get TrueNAS IP and API key (from Vault or prompt)
#   2. Fetch domain-join credentials from Vault
#   3. Configure DNS on TrueNAS to use Pi-hole
#   4. Join TrueNAS to AD domain
#   5. Configure SMB profile share
#   6. Save config to cluster-info.json
#
# Returns: 0 on success, 1 on failure
# joinTrueNASToADOnly - Join TrueNAS to AD without profile share configuration
function joinTrueNASToADOnly() {
  joinTrueNASToAD false
}

# joinTrueNASToADWithProfiles - Join TrueNAS to AD and configure profile share
function joinTrueNASToADWithProfiles() {
  joinTrueNASToAD true
}

# joinTrueNASToAD - Core function to join TrueNAS SCALE to the Samba AD domain
#
# Arguments: $1 - "true" to configure profile share, "false" to skip
function joinTrueNASToAD() {
  local CONFIGURE_PROFILES="${1:-true}"

  if [ "$CONFIGURE_PROFILES" = "true" ]; then
    cat <<EOF

############################################################################
TrueNAS Active Directory Join + Profile Share

Joins TrueNAS SCALE to the Active Directory domain and configures
an SMB share for user profiles.

Uses TrueNAS REST API — requires an API key from the TrueNAS UI.
#############################################################################

EOF
  else
    cat <<EOF

############################################################################
TrueNAS Active Directory Join

Joins TrueNAS SCALE to the Active Directory domain.

Uses TrueNAS REST API — requires an API key from the TrueNAS UI.
#############################################################################

EOF
  fi

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

  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ] || [ -z "$ROOT_TOKEN" ]; then
    error "Could not read Vault credentials"
    return 1
  fi

  # ==========================================================================
  # Step 1: Get TrueNAS connection details + API key
  # ==========================================================================

  # Check if TrueNAS IP is already saved
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

  # Get API key from Vault or prompt
  getTrueNASAPIKey || return 1

  # Verify API key works
  doing "Verifying TrueNAS API access..."
  local SYS_INFO
  SYS_INFO=$(truenasAPI GET /system/info)

  if [ -z "$SYS_INFO" ] || echo "$SYS_INFO" | jq -e '.error' > /dev/null 2>&1; then
    error "TrueNAS API authentication failed"
    error "Verify the API key is correct and has not expired."
    return 1
  fi

  local TRUENAS_VERSION
  TRUENAS_VERSION=$(echo "$SYS_INFO" | jq -r '.version // "unknown"')
  success "TrueNAS API connected (version: $TRUENAS_VERSION)"

  # ==========================================================================
  # Step 2: Fetch domain-join credentials from Vault
  # ==========================================================================

  doing "Fetching domain-join credentials from Vault..."

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
  # Step 3: Configure DNS + Join AD
  # ==========================================================================

  local AD_REALM_LOWER
  AD_REALM_LOWER=$(echo "$AD_REALM" | tr '[:upper:]' '[:lower:]')

  # Check current AD status
  doing "Checking if TrueNAS is already domain-joined..."
  local AD_CONFIG
  AD_CONFIG=$(truenasAPI GET /activedirectory) || AD_CONFIG="{}"

  local AD_ENABLED
  AD_ENABLED=$(echo "$AD_CONFIG" | jq -r '.enable // false')

  if [ "$AD_ENABLED" = "true" ]; then
    local CURRENT_DOMAIN
    CURRENT_DOMAIN=$(echo "$AD_CONFIG" | jq -r '.domainname // "unknown"')
    info "TrueNAS is already joined to: $CURRENT_DOMAIN"
    question "Re-join to $AD_REALM_LOWER? (y/N): "
    read -r REJOIN
    if [[ ! "$REJOIN" =~ ^[yY] ]]; then
      info "Skipping AD join"
      configureTrueNASProfileShare "$AD_REALM_LOWER"
      saveTrueNASConfig
      return 0
    fi

    # Leave current domain first
    doing "Leaving current AD domain..."
    truenasAPI PUT /activedirectory '{"enable": false}' > /dev/null || true
    sleep 3
  fi

  # Configure DNS to use Pi-hole
  local DNS_IP
  DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -n "$DNS_IP" ]; then
    doing "Configuring TrueNAS DNS to use Pi-hole only ($DNS_IP)..."
    # Clear all nameservers except Pi-hole — external DNS (e.g., 1.1.1.1) will
    # fail to resolve internal AD SRV records and cause the join to fail
    local DNS_RESULT
    DNS_RESULT=$(truenasAPI PUT /network/configuration \
      "{\"nameserver1\": \"${DNS_IP}\", \"nameserver2\": \"\", \"nameserver3\": \"\"}") || true

    if echo "$DNS_RESULT" | jq -e '.error' > /dev/null 2>&1; then
      warn "Could not update DNS via API: $(echo "$DNS_RESULT" | jq -r '.error // .message // "unknown error"')"
      warn "Set DNS manually: TrueNAS UI -> Network -> Global Configuration"
      warn "  Nameserver 1: ${DNS_IP}"
      warn "  Nameserver 2: (clear)"
      warn "  Nameserver 3: (clear)"
      question "Continue with AD join? DNS must resolve $AD_REALM_LOWER first. (Y/n): "
      read -r CONTINUE_JOIN
      if [[ "$CONTINUE_JOIN" =~ ^[nN] ]]; then
        info "Set DNS in TrueNAS UI, then re-run this option."
        return 1
      fi
    else
      success "TrueNAS DNS configured (Pi-hole only)"
    fi
  fi

  # Join AD domain — the PUT returns a job ID, not the config object
  doing "Joining TrueNAS to AD domain: $AD_REALM_LOWER..."
  info "  This may take 30-60 seconds..."

  local JOIN_PAYLOAD
  JOIN_PAYLOAD=$(jq -n \
    --arg domain "$AD_REALM_LOWER" \
    --arg bindpw "$DOMAIN_JOIN_PASSWORD" \
    '{
      domainname: $domain,
      bindname: "domain-join-svc",
      bindpw: $bindpw,
      enable: true
    }')

  local JOB_ID
  JOB_ID=$(truenasAPI PUT /activedirectory "$JOIN_PAYLOAD") || true

  # Response is a bare job ID number
  if ! [[ "$JOB_ID" =~ ^[0-9]+$ ]]; then
    # Not a job ID — might be an error object
    local ERR_MSG
    ERR_MSG=$(echo "$JOB_ID" | jq -r '.error // .message // "unknown error"' 2>/dev/null)
    error "Failed to initiate AD join: $ERR_MSG"
    echo
    info "Troubleshooting:"
    info "  1. Verify DNS: dig _ldap._tcp.${AD_REALM_LOWER} SRV (from TrueNAS)"
    info "  2. Verify credentials: vault kv get secret/samba-ad"
    info "  3. Check TrueNAS UI -> Directory Services for detailed errors"
    return 1
  fi

  info "  AD join job started (job ID: $JOB_ID)"

  # Poll the job until it completes or fails
  doing "Waiting for AD join to complete..."
  local MAX_WAIT=180
  local WAITED=0
  while [ $WAITED -lt $MAX_WAIT ]; do
    local JOB_STATUS
    JOB_STATUS=$(truenasAPI GET "/core/get_jobs?id=${JOB_ID}") || JOB_STATUS="[]"

    local JOB_STATE
    JOB_STATE=$(echo "$JOB_STATUS" | jq -r '.[0].state // "UNKNOWN"')

    case "$JOB_STATE" in
      SUCCESS)
        success "TrueNAS joined to AD domain: $AD_REALM_LOWER"
        break
        ;;
      FAILED)
        local JOB_ERROR
        JOB_ERROR=$(echo "$JOB_STATUS" | jq -r '.[0].error // "unknown error"')
        error "AD join failed: $JOB_ERROR"
        return 1
        ;;
      RUNNING|WAITING)
        local JOB_PROGRESS
        JOB_PROGRESS=$(echo "$JOB_STATUS" | jq -r '.[0].progress.description // ""')
        if [ -n "$JOB_PROGRESS" ]; then
          doing "  ${JOB_PROGRESS} (${WAITED}s / ${MAX_WAIT}s)"
        else
          doing "  Still waiting... (${WAITED}s / ${MAX_WAIT}s)"
        fi
        ;;
      *)
        doing "  Job state: $JOB_STATE (${WAITED}s / ${MAX_WAIT}s)"
        ;;
    esac

    sleep 5
    WAITED=$((WAITED + 5))
  done

  if [ $WAITED -ge $MAX_WAIT ]; then
    warn "AD join did not complete within ${MAX_WAIT}s"
    warn "Check TrueNAS UI -> Directory Services for status"
    warn "The join may still be in progress (job ID: $JOB_ID)"
  fi

  # Verify join
  doing "Verifying AD join..."
  local DOMAIN_INFO
  DOMAIN_INFO=$(truenasAPI GET /activedirectory) || DOMAIN_INFO="{}"

  local JOINED_DOMAIN
  JOINED_DOMAIN=$(echo "$DOMAIN_INFO" | jq -r '.domainname // "unknown"')
  local JOINED_ENABLED
  JOINED_ENABLED=$(echo "$DOMAIN_INFO" | jq -r '.enable // false')

  if [ "$JOINED_ENABLED" = "true" ]; then
    success "AD join verified: $JOINED_DOMAIN"
  else
    warn "AD join state unclear — check TrueNAS UI"
  fi

  # ==========================================================================
  # Step 4: Configure profile share (optional)
  # ==========================================================================

  if [ "$CONFIGURE_PROFILES" = "true" ]; then
    configureTrueNASProfileShare "$AD_REALM_LOWER"
  fi

  # ==========================================================================
  # Step 5: Save config
  # ==========================================================================

  saveTrueNASConfig

  echo
  if [ "$CONFIGURE_PROFILES" = "true" ]; then
    success "TrueNAS AD join and profile share configuration complete!"
    info "Profile Share: \\\\${TRUENAS_IP}\\profiles"
  else
    success "TrueNAS AD join complete!"
  fi
  echo
  info "TrueNAS: $TRUENAS_IP"
  info "AD Domain: $AD_REALM_LOWER"
  echo
}

# getTrueNASAPIKey - Get TrueNAS API key from Vault or prompt user
#
# Checks Vault at secret/truenas for a stored API key.
# If not found, prompts the user and stores it in Vault for next time.
#
# Sets global: TRUENAS_API_KEY
# Returns: 0 on success, 1 on failure
function getTrueNASAPIKey() {
  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  # Try to read from Vault first
  doing "Checking Vault for TrueNAS API key..."
  local TRUENAS_SECRETS
  TRUENAS_SECRETS=$(curl -sk --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/secret/data/truenas" \
    -H "X-Vault-Token: $ROOT_TOKEN" 2>/dev/null || echo "{}")

  TRUENAS_API_KEY=$(echo "$TRUENAS_SECRETS" | jq -r '.data.data.api_key // empty')

  if [ -n "$TRUENAS_API_KEY" ]; then
    success "Found TrueNAS API key in Vault"
    return 0
  fi

  # Not in Vault — prompt user
  info "No TrueNAS API key found in Vault."
  echo
  info "Generate an API key in TrueNAS:"
  info "  1. Log into TrueNAS web UI (https://$TRUENAS_IP)"
  info "  2. Click the user icon (top-right) -> API Keys"
  info "  3. Click Add -> name it 'proxmox-lab' -> Save"
  info "  4. Copy the key and paste it below"
  echo
  question "Enter TrueNAS API key: "
  read -rs TRUENAS_API_KEY
  echo

  if [ -z "$TRUENAS_API_KEY" ]; then
    error "API key is required"
    return 1
  fi

  # Store in Vault for next time
  doing "Storing TrueNAS API key in Vault..."

  local API_KEY_PAYLOAD
  API_KEY_PAYLOAD=$(jq -n \
    --arg api_key "$TRUENAS_API_KEY" \
    --arg ip "$TRUENAS_IP" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{data: {api_key: $api_key, ip: $ip, stored_at: $ts}}')

  if curl -skf --connect-timeout 5 --max-time 10 -X POST \
    "${VAULT_ADDR}/v1/secret/data/truenas" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$API_KEY_PAYLOAD" > /dev/null; then
    success "TrueNAS API key stored in Vault at secret/truenas"
  else
    warn "Could not store API key in Vault — you'll be prompted again next time"
  fi

  return 0
}

# configureTrueNASProfileShare - Configure SMB share for user profiles
#
# Creates or updates an SMB share on TrueNAS for roaming user profiles.
# The share is configured with AD group permissions.
#
# Arguments: $1 - AD realm (lowercase)
# Globals read: TRUENAS_IP, TRUENAS_API_KEY
# Returns: 0 on success (non-fatal on failure)
function configureTrueNASProfileShare() {
  local AD_REALM_LOWER="$1"

  doing "Configuring SMB profile share on TrueNAS..."

  # Check if profiles share already exists
  local SHARES
  SHARES=$(truenasAPI GET /sharing/smb) || SHARES="[]"

  local SHARE_EXISTS SHARE_ID
  SHARE_ID=$(echo "$SHARES" | jq -r '.[] | select(.name == "profiles") | .id // empty')
  SHARE_EXISTS=$( [ -n "$SHARE_ID" ] && echo "true" || echo "false" )

  if [ "$SHARE_EXISTS" = "true" ]; then
    info "SMB share 'profiles' already exists (id: $SHARE_ID)"
    question "Reconfigure share? (y/N): "
    read -r RECONFIG
    if [[ ! "$RECONFIG" =~ ^[yY] ]]; then
      info "Skipping share configuration"
      return 0
    fi
  fi

  # Prompt for dataset path
  local DEFAULT_DATASET="/mnt/pool/profiles"
  question "Enter TrueNAS dataset path for profiles [$DEFAULT_DATASET]: "
  read -r DATASET_PATH
  DATASET_PATH="${DATASET_PATH:-$DEFAULT_DATASET}"

  # Prompt for AD group
  local DEFAULT_GROUP="Domain Users"
  question "Enter AD group for profile access [$DEFAULT_GROUP]: "
  read -r AD_GROUP
  AD_GROUP="${AD_GROUP:-$DEFAULT_GROUP}"

  local SHARE_PAYLOAD
  SHARE_PAYLOAD=$(jq -n \
    --arg path "$DATASET_PATH" \
    '{
      name: "profiles",
      path: $path,
      purpose: "NO_PRESET",
      comment: "User profile storage (AD-integrated)",
      browsable: true,
      ro: false,
      guestok: false,
      abe: true
    }')

  if [ "$SHARE_EXISTS" = "true" ]; then
    doing "Updating existing 'profiles' SMB share..."
    local UPDATE_RESULT
    UPDATE_RESULT=$(truenasAPI PUT "/sharing/smb/id/${SHARE_ID}" "$SHARE_PAYLOAD") || true

    if echo "$UPDATE_RESULT" | jq -e '.error' > /dev/null 2>&1; then
      warn "Share update may have failed: $(echo "$UPDATE_RESULT" | jq -r '.error // "unknown"')"
      warn "Verify in TrueNAS UI -> Shares -> SMB"
      return 0
    fi
  else
    doing "Creating 'profiles' SMB share..."
    local CREATE_RESULT
    CREATE_RESULT=$(truenasAPI POST /sharing/smb "$SHARE_PAYLOAD") || true

    if echo "$CREATE_RESULT" | jq -e '.error' > /dev/null 2>&1; then
      warn "Share creation may have failed: $(echo "$CREATE_RESULT" | jq -r '.error // "unknown"')"
      warn "Verify in TrueNAS UI -> Shares -> SMB"
      return 0
    fi
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
function saveTrueNASConfig() {
  doing "Saving TrueNAS configuration to cluster-info.json..."

  local UPDATED
  UPDATED=$(jq \
    --arg ip "$TRUENAS_IP" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.truenas = {ip: $ip, joined_at: $ts}' \
    "$CLUSTER_INFO_FILE")

  echo "$UPDATED" > "$CLUSTER_INFO_FILE"
  success "TrueNAS config saved to cluster-info.json"
}
