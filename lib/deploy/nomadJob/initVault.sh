#!/usr/bin/env bash

# initVault - Initialize and unseal Vault, save credentials
#
# This is the one imperative step that can't be Terraformed:
# Vault must be initialized to generate the unseal key and root token,
# and these must be captured and saved to disk.
#
# After this runs, Layer 2 (terraform/services/) can configure
# everything else inside Vault declaratively.
#
# Globals read: VAULT_CREDENTIALS_FILE, SCRIPT_DIR
# Arguments: $1 - Vault IP (default: first Nomad node from hosts.json)
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Initializes Vault (1 key share, 1 threshold)
#   - Unseals Vault
#   - Saves unseal_key, root_token, vault_address to VAULT_CREDENTIALS_FILE
#   - Writes terraform/services/terraform.tfvars with vault/nomad addresses

# generateNASServersTfvars - Parse nas_servers from bootstrap.yml into HCL
#
# Reads the nas_servers list from bootstrap.yml and outputs HCL for the
# nas_servers variable in Layer 2 tfvars.
function generateNASServersTfvars() {
  local BOOTSTRAP="${SCRIPT_DIR}/bootstrap.yml"

  if ! command -v yq >/dev/null 2>&1 || [ ! -f "$BOOTSTRAP" ]; then
    echo "nas_servers = []"
    return 0
  fi

  local COUNT
  COUNT=$(yq '.nas_servers | length // 0' "$BOOTSTRAP" 2>/dev/null || echo 0)

  if [ "$COUNT" -eq 0 ] || [ "$COUNT" = "null" ]; then
    echo "nas_servers = []"
    return 0
  fi

  echo "nas_servers = ["
  for i in $(seq 0 $((COUNT - 1))); do
    echo "  {"
    for key in name type address api_key admin_user admin_password; do
      local val
      val=$(yq ".nas_servers[$i].$key // \"\"" "$BOOTSTRAP" 2>/dev/null)
      [ -n "$val" ] && [ "$val" != "null" ] && [ "$val" != '""' ] && echo "    $key = $val"
    done
    echo "  },"
  done
  echo "]"
}

# Write terraform/services/terraform.tfvars from current bootstrap.yml +
# cluster-info.json + crypto/vault-credentials.json. Idempotent — safe
# to call multiple times. Used by initAndUnsealVault on first deploy and
# by refreshLayer2Configs (in setup.sh) when bootstrap.yml changes.
#
# Arguments: $1 = nomad01 IP (used to construct nomad_address)
function writeServicesTfvars() {
  local VAULT_IP="${1:-}"
  if [ -z "$VAULT_IP" ]; then
    error "writeServicesTfvars: nomad01 IP required as first arg"
    return 1
  fi
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "writeServicesTfvars: $VAULT_CREDENTIALS_FILE missing"
    return 1
  fi
  if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    error "writeServicesTfvars: $CLUSTER_INFO_FILE missing"
    return 1
  fi

  local ROOT_TOKEN VAULT_ADDR_FINAL DNS_POSTFIX
  ROOT_TOKEN=$(jq -r '.root_token' "$VAULT_CREDENTIALS_FILE")
  VAULT_ADDR_FINAL=$(jq -r '.vault_address' "$VAULT_CREDENTIALS_FILE")
  DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")

  local SERVICES_TFVARS="${SCRIPT_DIR}/terraform/services/terraform.tfvars"
  local NOMAD_ADDR="http://${VAULT_IP}:4646"

  local DNS_SERVER_IP=""
  DNS_SERVER_IP=$(sed -n 's/^dns_primary_ipv4.*=.*"\(.*\)"/\1/p' "${SCRIPT_DIR}/terraform/terraform.tfvars" 2>/dev/null || true)

  local NOMAD_IPS_HCL=""
  NOMAD_IPS_HCL=$(sed -n 's/.*"\(nomad[0-9]*\)".*ip = "\([^"]*\)".*/  \1 = "\2"/p' "${SCRIPT_DIR}/terraform/terraform.tfvars" 2>/dev/null || true)

  local VM_INVENTORY_HCL=""
  VM_INVENTORY_HCL=$(
    sed -n 's/.*"\([a-z0-9]*\)".*vm_id = \([0-9]*\).*ip = "\([^"]*\)".*cores = \([0-9]*\).*memory = \([0-9]*\).*disk_size = "\([^"]*\)".*target_node = "\([^"]*\)".*/  \1 = { vm_id = \2, ip = "\3", cores = \4, memory = \5, disk_size = "\6", target_node = "\7" }/p' \
      "${SCRIPT_DIR}/terraform/terraform.tfvars" 2>/dev/null
    if [ -f "${SCRIPT_DIR}/terraform/vm-kasm/variables.tf" ]; then
      sed -n 's/.*"\([a-z0-9]*\)".*vm_id = \([0-9]*\).*ip = "\([^"]*\)".*cores = \([0-9]*\).*memory = \([0-9]*\).*disk_size = "\([^"]*\)".*target_node = "\([^"]*\)".*/  \1 = { vm_id = \2, ip = "\3", cores = \4, memory = \5, disk_size = "\6", target_node = "\7" }/p' "${SCRIPT_DIR}/terraform/vm-kasm/variables.tf" 2>/dev/null
    fi
    true
  )
  VM_INVENTORY_HCL=$(echo "$VM_INVENTORY_HCL" | sort -u)

  # Preserve user-edited values that aren't derived from bootstrap.yml.
  # configure_authentik / configure_netbox toggle as part of two-phase
  # deploys; netbox_api_token is fetched after Netbox starts.
  local PREV_CFG_AUTH PREV_CFG_NETBOX PREV_NETBOX_TOKEN
  if [ -f "$SERVICES_TFVARS" ]; then
    PREV_CFG_AUTH=$(sed -n 's/^configure_authentik.*=.*\([a-z]*\)/\1/p' "$SERVICES_TFVARS" 2>/dev/null | head -1)
    PREV_CFG_NETBOX=$(sed -n 's/^configure_netbox.*=.*\([a-z]*\)/\1/p' "$SERVICES_TFVARS" 2>/dev/null | head -1)
    PREV_NETBOX_TOKEN=$(sed -n 's/^netbox_api_token.*=.*"\(.*\)"/\1/p' "$SERVICES_TFVARS" 2>/dev/null | head -1)
  fi
  : "${PREV_CFG_AUTH:=false}"
  : "${PREV_CFG_NETBOX:=false}"
  : "${PREV_NETBOX_TOKEN:=not-configured}"

  cat > "$SERVICES_TFVARS" <<EOF
# =============================================================================
# Layer 2 — Auto-generated (writeServicesTfvars)
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# =============================================================================

vault_address   = "${VAULT_ADDR_FINAL}"
vault_token     = "${ROOT_TOKEN}"
nomad_address   = "${NOMAD_ADDR}"
dns_postfix     = "${DNS_POSTFIX}"
dns_server_ip   = "${DNS_SERVER_IP}"
network_gateway = "$(jq -r '.network.external.gateway // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)"
network_cidr    = "$(jq -r '.network.external.cidr // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)"

nomad_node_ips = {
${NOMAD_IPS_HCL}
}

vm_inventory = {
${VM_INVENTORY_HCL}
}

lxc_inventory = {
$(awk '/dns_main_nodes/,/]/' "${SCRIPT_DIR}/terraform/terraform.tfvars" 2>/dev/null | \
  awk '/hostname/{h=$3} /target_node/{t=$3} /ip/{print "  " h " = { ip = " $3 ", target_node = " t ", role = \"dns\" }"}' 2>/dev/null || true)
}

ad_realm  = "$(echo "${DNS_POSTFIX}" | tr '[:lower:]' '[:upper:]')"
ad_domain = "$(echo "${DNS_POSTFIX}" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')"

ssh_admin_private_key_file      = "/crypto/labadmin"
ssh_admin_public_key_file       = "/crypto/labadmin.pub"
ssh_enterprise_private_key_file = "/crypto/labenterpriseadmin"

traefik_ha_vip = "$(sed -n 's/^nomad_traefik_ha_vip.*=.*"\(.*\)"/\1/p' "${SCRIPT_DIR}/terraform/terraform.tfvars" 2>/dev/null || true)"
dns_ha_vip     = "$(sed -n 's/^dns_ha_vip_address.*=.*"\(.*\)"/\1/p' "${SCRIPT_DIR}/terraform/terraform.tfvars" 2>/dev/null || true)"

proxmox_node_ips = {
$(jq -r '.nodes[] | "  \(.name) = \"\(.ip)\""' "$CLUSTER_INFO_FILE" 2>/dev/null || true)
}

kasm_ip = "$(sed -n 's/.*"kasm01".*ip = "\([^"]*\)".*/\1/p' "${SCRIPT_DIR}/terraform/terraform.tfvars" 2>/dev/null || true)"

pihole_admin_password = "$(curl -sk -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR_FINAL}/v1/secret/data/pihole" 2>/dev/null | jq -r '.data.data.admin_password // ""' 2>/dev/null || true)"

authentik_api_token = "$(curl -sk -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR_FINAL}/v1/secret/data/authentik" 2>/dev/null | jq -r '.data.data.api_token // "not-configured"' 2>/dev/null || echo "not-configured")"

# Two-phase toggles — preserved across re-runs
configure_authentik = ${PREV_CFG_AUTH}
configure_netbox    = ${PREV_CFG_NETBOX}
netbox_api_token    = "${PREV_NETBOX_TOKEN}"

# Roaming profiles (from bootstrap.yml)
profile_server       = "$(yq -r '.profile_server // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
profile_share        = "$(yq -r '.profile_share // "profiles"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "profiles")"
profile_drive_letter = "$(yq -r '.profile_drive_letter // "P"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "P")"

deploy_traefik = true

# NAS servers (from bootstrap.yml)
$(generateNASServersTfvars)

# UniFi Controller (from bootstrap.yml)
unifi_address = "$(yq -r '.unifi_address // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
unifi_api_key = "$(yq -r '.unifi_api_key // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
unifi_site    = "$(yq -r '.unifi_site // "default"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "default")"

# Netbox periodic inventory sync (from bootstrap.yml — defaults to every 6h)
netbox_sync_cron     = "$(yq -r '.netbox_sync_cron // "0 */6 * * *"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "0 */6 * * *")"
netbox_sync_timezone = "$(yq -r '.netbox_sync_timezone // "UTC"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "UTC")"
EOF

  chmod 600 "$SERVICES_TFVARS"
}

function initAndUnsealVault() {
  local VAULT_IP="${1:-}"

  if [ -z "$VAULT_IP" ]; then
    VAULT_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
  fi

  if [ -z "$VAULT_IP" ]; then
    error "Could not determine Vault IP. Provide it as argument or ensure hosts.json exists."
    return 1
  fi

  # Determine protocol — check if Vault is already serving HTTPS
  local VAULT_PROTO="http"
  if curl -sk --connect-timeout 2 --max-time 3 "https://$VAULT_IP:8200/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1; then
    VAULT_PROTO="https"
  fi

  local VAULT_ADDR="${VAULT_PROTO}://${VAULT_IP}:8200"
  doing "Checking Vault at $VAULT_ADDR..."

  # Check init status
  local VAULT_STATUS
  VAULT_STATUS=$(curl -skf --connect-timeout 5 --max-time 10 "${VAULT_ADDR}/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" 2>/dev/null || echo '{"initialized": false}')

  local IS_INITIALIZED
  IS_INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')

  if [ "$IS_INITIALIZED" = "false" ]; then
    doing "Initializing Vault (1 key share for home lab)..."

    local INIT_RESPONSE
    INIT_RESPONSE=$(curl -skf --connect-timeout 5 --max-time 30 -X PUT "${VAULT_ADDR}/v1/sys/init" \
      -H "Content-Type: application/json" \
      -d '{"secret_shares": 1, "secret_threshold": 1}' 2>&1)

    local UNSEAL_KEY ROOT_TOKEN
    UNSEAL_KEY=$(echo "$INIT_RESPONSE" | jq -r '.keys[0]')
    ROOT_TOKEN=$(echo "$INIT_RESPONSE" | jq -r '.root_token')

    if [ -z "$UNSEAL_KEY" ] || [ "$UNSEAL_KEY" = "null" ]; then
      error "Failed to initialize Vault"
      echo "$INIT_RESPONSE"
      return 1
    fi

    success "Vault initialized"

    # Save credentials IMMEDIATELY — if anything fails after this,
    # we still have the unseal key and root token on disk
    mkdir -p "$(dirname "$VAULT_CREDENTIALS_FILE")"
    cat > "$VAULT_CREDENTIALS_FILE" <<EOF
{
  "unseal_key": "$UNSEAL_KEY",
  "root_token": "$ROOT_TOKEN",
  "vault_address": "$VAULT_ADDR",
  "initialized_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "$VAULT_CREDENTIALS_FILE"
    success "Credentials saved to $VAULT_CREDENTIALS_FILE"

    # Unseal
    doing "Unsealing Vault..."
    curl -skf --connect-timeout 5 --max-time 10 -X PUT "${VAULT_ADDR}/v1/sys/unseal" \
      -H "Content-Type: application/json" \
      -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null

    success "Vault unsealed"

  else
    info "Vault already initialized"

    # Recovery: Vault is initialized but we have no credentials file.
    # This means a previous deployment crashed after init but the unseal
    # key was lost. Stop Vault, wipe data, redeploy, and re-init fresh.
    if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
      warn "Vault initialized but no credentials file found"
      warn "Previous deployment likely failed — recovering with fresh init..."

      # Stop and purge the Vault job
      doing "Stopping Vault..."
      ssh -o StrictHostKeyChecking=no -i "${ADMIN_KEY_PATH:-${SCRIPT_DIR}/crypto/labadmin}" \
        labadmin@${VAULT_IP} "nomad job stop -purge vault 2>/dev/null || true" || true
      sleep 3

      # Wipe Vault data and all service data that depends on Vault secrets
      # (Authentik DB has bootstrap token/passwords baked in from old Vault)
      doing "Wiping stale Vault and service data..."
      ssh -o StrictHostKeyChecking=no -i "${ADMIN_KEY_PATH:-${SCRIPT_DIR}/crypto/labadmin}" \
        labadmin@${VAULT_IP} "sudo rm -rf /srv/gluster/nomad-data/vault/* /srv/gluster/nomad-data/vault-tls/* /srv/gluster/nomad-data/authentik/postgres/* /srv/gluster/nomad-data/authentik/data/*" || true

      # Clear stale Layer 2 state
      rm -f "${SCRIPT_DIR}/terraform/services/terraform.tfstate" "${SCRIPT_DIR}/terraform/services/terraform.tfstate.backup" 2>/dev/null || true

      # Redeploy Vault container fresh
      doing "Redeploying Vault..."
      docker compose run --rm -T terraform apply -auto-approve \
        -var "nomad_address=http://${VAULT_IP}:4646" \
        -target=nomad_job.vault \
        -target=null_resource.vault_directories || { error "Failed to redeploy Vault"; return 1; }

      # Wait for Vault to start
      sleep 5

      # Recurse — Vault should now be uninitialized
      doing "Retrying Vault initialization..."
      initAndUnsealVault "$VAULT_IP"
      return $?
    fi

    # Normal path: credentials file exists, unseal with saved key
    local IS_SEALED
    IS_SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed // true')

    if [ "$IS_SEALED" = "true" ]; then
      doing "Vault is sealed, unsealing with saved key..."
      local UNSEAL_KEY
      UNSEAL_KEY=$(jq -r '.unseal_key // empty' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
      if [ -z "$UNSEAL_KEY" ]; then
        error "Unseal key missing from credentials file"
        return 1
      fi
      curl -skf --connect-timeout 5 --max-time 10 -X PUT "${VAULT_ADDR}/v1/sys/unseal" \
        -H "Content-Type: application/json" \
        -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null
      success "Vault unsealed"
    else
      success "Vault is already unsealed"
    fi

    # Update vault_address if it changed (e.g., http -> https)
    local STORED_ADDR
    STORED_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
    if [ "$STORED_ADDR" != "$VAULT_ADDR" ] && [ -n "$STORED_ADDR" ]; then
      doing "Updating vault_address: $STORED_ADDR → $VAULT_ADDR"
      local tmp; tmp=$(mktemp)
      jq --arg addr "$VAULT_ADDR" '.vault_address = $addr' "$VAULT_CREDENTIALS_FILE" > "$tmp" && mv "$tmp" "$VAULT_CREDENTIALS_FILE"
      chmod 600 "$VAULT_CREDENTIALS_FILE"
    fi
  fi

  # Write Layer 2 tfvars via the shared helper
  doing "Writing terraform/services/terraform.tfvars..."
  writeServicesTfvars "$VAULT_IP" || return 1
  success "terraform/services/terraform.tfvars written"

  # Also update Layer 1 vault.auto.tfvars (consumed by terraform/main.tf)
  local ROOT_TOKEN VAULT_ADDR_FINAL
  ROOT_TOKEN=$(jq -r '.root_token' "$VAULT_CREDENTIALS_FILE")
  VAULT_ADDR_FINAL=$(jq -r '.vault_address' "$VAULT_CREDENTIALS_FILE")
  local NOMAD_ADDR="http://${VAULT_IP}:4646"
  cat > "${SCRIPT_DIR}/terraform/vault.auto.tfvars" <<EOF
vault_address = "${VAULT_ADDR_FINAL}"
vault_token   = "${ROOT_TOKEN}"
nomad_address = "${NOMAD_ADDR}"
EOF
  chmod 600 "${SCRIPT_DIR}/terraform/vault.auto.tfvars"
  success "terraform/vault.auto.tfvars written"

  echo
  success "Vault is ready. Run Layer 2 to configure services:"
  info "  docker compose run --rm -it terraform-services apply"
}
