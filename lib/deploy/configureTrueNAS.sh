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
  # Step 1: Migrate any legacy singleton config, then select or add a NAS
  # ==========================================================================

  migrateTrueNASConfig || true

  TRUENAS_NAME=""
  TRUENAS_IP=""
  TRUENAS_API_KEY=""
  TRUENAS_IS_NEW=false
  selectOrAddTrueNAS || return 1

  if [ "$TRUENAS_IS_NEW" = "true" ]; then
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

  # Load (existing) or prompt (new) for the API key.
  # For new NASes the key is persisted to Vault only after we discover the
  # authoritative hostname below.
  getTrueNASAPIKey "$TRUENAS_NAME" || return 1

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

  # For new entries, discover the authoritative hostname and persist the key.
  if [ "$TRUENAS_IS_NEW" = "true" ]; then
    local RAW_HOST
    RAW_HOST=$(fetchTrueNASHostname)
    if [ -z "$RAW_HOST" ]; then
      error "Could not read TrueNAS hostname via API"
      return 1
    fi
    TRUENAS_NAME=$(normalizeTrueNASName "$RAW_HOST")
    if [ -z "$TRUENAS_NAME" ]; then
      error "Could not normalize TrueNAS hostname '$RAW_HOST'"
      return 1
    fi
    info "TrueNAS hostname: $RAW_HOST  →  key: $TRUENAS_NAME"

    if jq -e --arg n "$TRUENAS_NAME" '(.truenas // {}) | has($n)' "$CLUSTER_INFO_FILE" > /dev/null 2>&1 \
       && [ "$(jq -r --arg n "$TRUENAS_NAME" '(.truenas // {}) | has($n)' "$CLUSTER_INFO_FILE")" = "true" ]; then
      warn "An entry for '$TRUENAS_NAME' already exists and will be overwritten."
      question "Continue? (y/N): "
      read -r CONFIRM_OVERWRITE
      if [[ ! "$CONFIRM_OVERWRITE" =~ ^[yY] ]]; then
        info "Aborted."
        return 1
      fi
    fi

    persistTrueNASAPIKey "$TRUENAS_NAME"
  fi

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

  # Check current AD status (TrueNAS SCALE 25.10+ /directoryservices API)
  doing "Checking if TrueNAS is already domain-joined..."
  local AD_CONFIG
  AD_CONFIG=$(truenasAPI GET /directoryservices) || AD_CONFIG="{}"

  local AD_ENABLED
  AD_ENABLED=$(echo "$AD_CONFIG" | jq -r 'if (.service_type == "ACTIVEDIRECTORY" and .enable == true) then "true" else "false" end')

  if [ "$AD_ENABLED" = "true" ]; then
    local CURRENT_DOMAIN
    CURRENT_DOMAIN=$(echo "$AD_CONFIG" | jq -r '.configuration.domain // .kerberos_realm // "unknown"')
    info "TrueNAS is already joined to: $CURRENT_DOMAIN"
    question "Re-join to $AD_REALM_LOWER? (y/N): "
    read -r REJOIN
    if [[ ! "$REJOIN" =~ ^[yY] ]]; then
      info "Skipping AD join"
      if [ "$CONFIGURE_PROFILES" = "true" ]; then
        configureTrueNASProfileShare "$AD_REALM_LOWER"
      fi
      saveTrueNASConfig "$TRUENAS_NAME"
      return 0
    fi

    # Leave current domain via /directoryservices/leave (uses KERBEROS_USER
    # credential; the old /activedirectory "clear kerberos_principal" quirk is
    # no longer relevant under the new API).
    doing "Leaving current AD domain..."
    local LEAVE_PAYLOAD
    LEAVE_PAYLOAD=$(jq -n --arg pw "$DOMAIN_JOIN_PASSWORD" \
      '{credential: {credential_type: "KERBEROS_USER", username: "domain-join-svc", password: $pw}}')
    local LEAVE_JOB
    LEAVE_JOB=$(truenasAPI POST /directoryservices/leave "$LEAVE_PAYLOAD") || true

    if [[ "$LEAVE_JOB" =~ ^[0-9]+$ ]]; then
      doing "  Waiting for domain leave to complete..."
      local LEAVE_WAITED=0
      while [ $LEAVE_WAITED -lt 30 ]; do
        local LEAVE_STATE
        LEAVE_STATE=$(truenasAPI GET "/core/get_jobs?id=${LEAVE_JOB}" | jq -r '.[0].state // "UNKNOWN"') || LEAVE_STATE="UNKNOWN"
        [[ "$LEAVE_STATE" == "SUCCESS" || "$LEAVE_STATE" == "FAILED" ]] && break
        sleep 3
        LEAVE_WAITED=$((LEAVE_WAITED + 3))
      done
      if [ "$LEAVE_STATE" = "FAILED" ]; then
        local LEAVE_ERR
        LEAVE_ERR=$(truenasAPI GET "/core/get_jobs?id=${LEAVE_JOB}" | jq -r '.[0].error // "unknown"')
        warn "Leave job reported FAILED: $LEAVE_ERR"
        warn "Continuing anyway — re-join may recover."
      fi
    else
      local LEAVE_ERR_MSG
      LEAVE_ERR_MSG=$(echo "$LEAVE_JOB" | jq -r '.message // .error // "(no message)"' 2>/dev/null)
      warn "Leave request did not return a job ID: $LEAVE_ERR_MSG"
      sleep 5
    fi
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

  # Join AD domain — PUT /directoryservices returns a job ID.
  # configuration.hostname is required (minLength 1), so fetch the system hostname.
  local TRUENAS_HOSTNAME
  TRUENAS_HOSTNAME=$(truenasAPI GET /network/configuration | jq -r '.hostname // empty') || TRUENAS_HOSTNAME=""

  if [ -z "$TRUENAS_HOSTNAME" ]; then
    error "Could not read TrueNAS system hostname — required for AD registration."
    return 1
  fi

  # 25.10 requires the Kerberos realm to exist in the local realms list before
  # the AD join will accept it. Older /activedirectory auto-created the realm;
  # /directoryservices does not. Create it if missing.
  doing "Ensuring Kerberos realm $AD_REALM is registered..."
  local REALM_LIST REALM_EXISTS
  REALM_LIST=$(truenasAPI GET /kerberos/realm) || REALM_LIST="[]"
  REALM_EXISTS=$(echo "$REALM_LIST" | jq -r --arg r "$AD_REALM" 'any(.realm == $r) // false')

  if [ "$REALM_EXISTS" != "true" ]; then
    local REALM_PAYLOAD REALM_RESULT
    REALM_PAYLOAD=$(jq -n --arg r "$AD_REALM" '{realm: $r}')
    REALM_RESULT=$(truenasAPI POST /kerberos/realm "$REALM_PAYLOAD") || true
    if echo "$REALM_RESULT" | jq -e '.id' > /dev/null 2>&1; then
      success "Kerberos realm $AD_REALM registered (id: $(echo "$REALM_RESULT" | jq -r '.id'))"
    else
      local REALM_ERR
      REALM_ERR=$(echo "$REALM_RESULT" | jq -r '.message // .error // "unknown error"' 2>/dev/null)
      error "Could not register Kerberos realm $AD_REALM: $REALM_ERR"
      return 1
    fi
  else
    info "Kerberos realm $AD_REALM already registered."
  fi

  doing "Joining TrueNAS to AD domain: $AD_REALM_LOWER..."
  info "  NetBIOS / AD computer name: $(echo "$TRUENAS_HOSTNAME" | tr '[:lower:]' '[:upper:]')"
  info "  This may take 30-60 seconds..."

  local JOIN_PAYLOAD
  JOIN_PAYLOAD=$(jq -n \
    --arg realm "$AD_REALM" \
    --arg dns_domain "$AD_REALM_LOWER" \
    --arg pw "$DOMAIN_JOIN_PASSWORD" \
    --arg host "$TRUENAS_HOSTNAME" \
    '{
      service_type: "ACTIVEDIRECTORY",
      credential: {
        credential_type: "KERBEROS_USER",
        username: "domain-join-svc",
        password: $pw
      },
      kerberos_realm: $realm,
      configuration: {
        service_type: "ACTIVEDIRECTORY",
        hostname: ($host | ascii_upcase),
        domain: $dns_domain
      },
      enable: true
    }')

  local JOB_ID
  JOB_ID=$(truenasAPI PUT /directoryservices "$JOIN_PAYLOAD") || true

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

  # Verify join (TrueNAS 25.10+ /directoryservices)
  doing "Verifying AD join..."
  local DOMAIN_INFO
  DOMAIN_INFO=$(truenasAPI GET /directoryservices) || DOMAIN_INFO="{}"

  local JOINED_DOMAIN JOINED_ENABLED
  JOINED_DOMAIN=$(echo "$DOMAIN_INFO" | jq -r '.configuration.domain // .kerberos_realm // "unknown"')
  JOINED_ENABLED=$(echo "$DOMAIN_INFO" | jq -r 'if (.service_type == "ACTIVEDIRECTORY" and .enable == true) then "true" else "false" end')

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

  saveTrueNASConfig "$TRUENAS_NAME"

  echo
  if [ "$CONFIGURE_PROFILES" = "true" ]; then
    success "TrueNAS AD join and profile share configuration complete!"
    info "Profile Share: \\\\${TRUENAS_IP}\\profiles"
  else
    success "TrueNAS AD join complete!"
  fi
  echo
  info "TrueNAS: $TRUENAS_NAME ($TRUENAS_IP)"
  info "AD Domain: $AD_REALM_LOWER"
  echo
}

# normalizeTrueNASName - Normalize a hostname for use as a cluster-info / Vault key
#
# Strips any DNS suffix (first label only) and lowercases.
function normalizeTrueNASName() {
  local RAW="$1"
  echo "$RAW" | cut -d'.' -f1 | tr '[:upper:]' '[:lower:]'
}

# fetchTrueNASHostname - Read the TrueNAS system hostname via its REST API.
#
# Globals read: TRUENAS_IP, TRUENAS_API_KEY
function fetchTrueNASHostname() {
  truenasAPI GET /network/configuration | jq -r '.hostname // empty'
}

# getTrueNASAPIKey - Load the API key for a named TrueNAS, or prompt for one.
#
# Arguments: $1 - hostname key (may be empty when adding a new NAS)
#
# If a name is given, reads secret/truenas/<name> from Vault. If nothing is
# stored there (or no name is given), prompts the user; the caller is
# responsible for persisting the key once the authoritative hostname is known
# (see persistTrueNASAPIKey).
#
# Sets global: TRUENAS_API_KEY
function getTrueNASAPIKey() {
  local NAME="${1:-}"
  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -n "$NAME" ]; then
    doing "Looking up TrueNAS API key in Vault (secret/truenas/${NAME})..."
    local SECRET
    SECRET=$(curl -sk --connect-timeout 5 --max-time 10 \
      "${VAULT_ADDR}/v1/secret/data/truenas/${NAME}" \
      -H "X-Vault-Token: $ROOT_TOKEN" 2>/dev/null || echo "{}")
    TRUENAS_API_KEY=$(echo "$SECRET" | jq -r '.data.data.api_key // empty')
    if [ -n "$TRUENAS_API_KEY" ]; then
      success "Found TrueNAS API key in Vault"
      return 0
    fi
    info "No API key stored at secret/truenas/${NAME} — prompting."
  fi

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

  return 0
}

# persistTrueNASAPIKey - Write the current TRUENAS_API_KEY to Vault under
# the given hostname key.
#
# Arguments: $1 - hostname key (required)
# Globals read: TRUENAS_API_KEY, TRUENAS_IP
function persistTrueNASAPIKey() {
  local NAME="$1"
  if [ -z "$NAME" ]; then
    warn "persistTrueNASAPIKey called without a name — skipping."
    return 1
  fi

  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  doing "Storing TrueNAS API key in Vault (secret/truenas/${NAME})..."

  local PAYLOAD
  PAYLOAD=$(jq -n \
    --arg api_key "$TRUENAS_API_KEY" \
    --arg ip "$TRUENAS_IP" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{data: {api_key: $api_key, ip: $ip, stored_at: $ts}}')

  if curl -skf --connect-timeout 5 --max-time 10 -X POST \
    "${VAULT_ADDR}/v1/secret/data/truenas/${NAME}" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" > /dev/null; then
    success "TrueNAS API key stored at secret/truenas/${NAME}"
  else
    warn "Could not store API key in Vault — you'll be prompted again next time"
  fi
}

# migrateTrueNASConfig - Idempotently upgrade legacy singleton state to the
# hostname-keyed layout.
#
# Old layout:
#   cluster-info.json: .truenas = { ip, joined_at }
#   Vault:             secret/truenas = { api_key, ip, stored_at }
#
# New layout:
#   cluster-info.json: .truenas = { "<hostname>": { ip, joined_at } }
#   Vault:             secret/truenas/<hostname> = { api_key, ip, stored_at }
#
# Safe to call multiple times — returns immediately if no legacy data exists.
function migrateTrueNASConfig() {
  local OLD_IP OLD_JOINED
  OLD_IP=$(jq -r '.truenas.ip // empty' "$CLUSTER_INFO_FILE" 2>/dev/null)
  OLD_JOINED=$(jq -r '.truenas.joined_at // empty' "$CLUSTER_INFO_FILE" 2>/dev/null)

  if [ -z "$OLD_IP" ]; then
    return 0
  fi

  info "Detected legacy single-NAS TrueNAS config — migrating to per-host layout..."

  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  local OLD_SECRET OLD_API_KEY
  OLD_SECRET=$(curl -sk --connect-timeout 5 --max-time 10 \
    "${VAULT_ADDR}/v1/secret/data/truenas" \
    -H "X-Vault-Token: $ROOT_TOKEN" 2>/dev/null || echo "{}")
  OLD_API_KEY=$(echo "$OLD_SECRET" | jq -r '.data.data.api_key // empty')

  if [ -z "$OLD_API_KEY" ]; then
    warn "Legacy .truenas entry exists but no API key at secret/truenas."
    warn "Cannot auto-discover the hostname; leaving legacy entry in place."
    warn "Re-run this option once the NAS is reachable with a valid key."
    return 0
  fi

  TRUENAS_IP="$OLD_IP"
  TRUENAS_API_KEY="$OLD_API_KEY"
  local RAW_HOST
  RAW_HOST=$(fetchTrueNASHostname)
  if [ -z "$RAW_HOST" ]; then
    warn "Could not reach legacy NAS at $OLD_IP to read its hostname."
    warn "Leaving legacy config in place; re-run once the NAS is reachable."
    TRUENAS_IP=""
    TRUENAS_API_KEY=""
    return 0
  fi

  local NAME
  NAME=$(normalizeTrueNASName "$RAW_HOST")
  if [ -z "$NAME" ]; then
    warn "Empty normalized hostname — aborting migration."
    TRUENAS_IP=""
    TRUENAS_API_KEY=""
    return 0
  fi

  info "  Legacy NAS hostname: $RAW_HOST  →  key: $NAME"

  # Write the new per-host Vault entry, preserving the existing fields.
  local NEW_PAYLOAD
  NEW_PAYLOAD=$(echo "$OLD_SECRET" | jq '{data: .data.data}')
  if ! curl -skf --connect-timeout 5 --max-time 10 -X POST \
      "${VAULT_ADDR}/v1/secret/data/truenas/${NAME}" \
      -H "X-Vault-Token: $ROOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$NEW_PAYLOAD" > /dev/null; then
    warn "Failed to write secret/truenas/${NAME}; leaving legacy entry in place."
    TRUENAS_IP=""
    TRUENAS_API_KEY=""
    return 0
  fi

  # Remove the legacy Vault entry (metadata delete removes all versions).
  curl -sk --connect-timeout 5 --max-time 10 -X DELETE \
    "${VAULT_ADDR}/v1/secret/metadata/truenas" \
    -H "X-Vault-Token: $ROOT_TOKEN" > /dev/null 2>&1 || true

  # Rewrite cluster-info.json: replace singleton with a map entry.
  local UPDATED
  UPDATED=$(jq \
    --arg name "$NAME" \
    --arg ip "$OLD_IP" \
    --arg ts "$OLD_JOINED" \
    '.truenas = {($name): {ip: $ip, joined_at: $ts}}' \
    "$CLUSTER_INFO_FILE")
  echo "$UPDATED" > "$CLUSTER_INFO_FILE"

  success "Migrated legacy TrueNAS entry to key: $NAME"
  echo

  # Reset globals so the main flow picks fresh values.
  TRUENAS_IP=""
  TRUENAS_API_KEY=""
}

# selectOrAddTrueNAS - Prompt the user to pick an existing TrueNAS entry
# from cluster-info.json, or choose to add a new one.
#
# Sets globals:
#   TRUENAS_NAME   - the hostname key (empty when adding new)
#   TRUENAS_IP     - the stored IP (empty when adding new)
#   TRUENAS_IS_NEW - "true" when the user is adding a new NAS
function selectOrAddTrueNAS() {
  local ENTRIES
  ENTRIES=$(jq -r '(.truenas // {}) | keys[]?' "$CLUSTER_INFO_FILE" 2>/dev/null)

  if [ -z "$ENTRIES" ]; then
    info "No TrueNAS servers configured yet — adding a new one."
    TRUENAS_NAME=""
    TRUENAS_IP=""
    TRUENAS_IS_NEW=true
    return 0
  fi

  echo
  info "Known TrueNAS servers:"
  local i=0
  local -a NAME_ARR=()
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    i=$((i + 1))
    NAME_ARR+=("$n")
    local EIP EJOINED
    EIP=$(jq -r --arg n "$n" '.truenas[$n].ip // "?"' "$CLUSTER_INFO_FILE")
    EJOINED=$(jq -r --arg n "$n" '.truenas[$n].joined_at // "?"' "$CLUSTER_INFO_FILE")
    info "  $i) $n — $EIP (joined $EJOINED)"
  done <<< "$ENTRIES"
  local ADD_IDX=$((i + 1))
  info "  $ADD_IDX) Add a new TrueNAS server"
  echo

  local CHOICE
  question "Select [1-$ADD_IDX]: "
  read -r CHOICE

  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$ADD_IDX" ]; then
    error "Invalid selection."
    return 1
  fi

  if [ "$CHOICE" -eq "$ADD_IDX" ]; then
    TRUENAS_NAME=""
    TRUENAS_IP=""
    TRUENAS_IS_NEW=true
  else
    TRUENAS_NAME="${NAME_ARR[$((CHOICE - 1))]}"
    TRUENAS_IP=$(jq -r --arg n "$TRUENAS_NAME" '.truenas[$n].ip // empty' "$CLUSTER_INFO_FILE")
    TRUENAS_IS_NEW=false
    info "Selected: $TRUENAS_NAME ($TRUENAS_IP)"
  fi
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

# saveTrueNASConfig - Upsert a TrueNAS entry in cluster-info.json under
# .truenas[<name>].
#
# Arguments: $1 - hostname key (required)
# Globals read: TRUENAS_IP
function saveTrueNASConfig() {
  local NAME="$1"
  if [ -z "$NAME" ]; then
    warn "saveTrueNASConfig called without a name — skipping."
    return 1
  fi

  doing "Saving TrueNAS configuration to cluster-info.json..."

  local UPDATED
  UPDATED=$(jq \
    --arg name "$NAME" \
    --arg ip "$TRUENAS_IP" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.truenas = ((.truenas // {}) + {($name): {ip: $ip, joined_at: $ts}})' \
    "$CLUSTER_INFO_FILE")

  echo "$UPDATED" > "$CLUSTER_INFO_FILE"
  success "TrueNAS config saved: .truenas[$NAME]"
}
