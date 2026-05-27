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
    # Use -o=json so strings get JSON-quoted ("foo") and bools/numbers
    # stay unquoted — both are valid HCL value syntax. Raw yq output
    # (without -o=json) emits unquoted strings, which breaks HCL parsing
    # the moment any field contains a space or special char (e.g.,
    # profile_ad_group = "Domain Users").
    for key in name type address api_key admin_user admin_password pool provides_profiles profile_dataset profile_ad_group; do
      local val
      val=$(yq -o=json -I=0 ".nas_servers[$i].$key // \"\"" "$BOOTSTRAP" 2>/dev/null)
      [ -n "$val" ] && [ "$val" != "null" ] && [ "$val" != '""' ] && echo "    $key = $val"
    done
    echo "  },"
  done
  echo "]"
}

# generateNASStorageTfvars — emit the nas_storage object (cluster_state +
# snapshots) from bootstrap.yml storage.cluster_state / storage.snapshots.
# Sub-keys live under the existing storage:* block to avoid colliding with
# the Proxmox storage pool overrides (storage.templates, storage.runtime).
# Empty / missing → emits a zero-valued block; the cluster_state.nas being
# blank is what gates whether nas-shares.tf creates any datasets.
function generateNASStorageTfvars() {
  local BOOTSTRAP="${SCRIPT_DIR}/bootstrap.yml"
  if ! command -v yq >/dev/null 2>&1 || [ ! -f "$BOOTSTRAP" ]; then
    cat <<'EOF'
nas_storage = {
  cluster_state = { nas = "", dataset_root = "nomad", allow_hosts = "" }
  snapshots = {
    schedule          = "hourly"
    retention_hourly  = 96
    retention_daily   = 30
    retention_monthly = 12
    replicate_to      = { nas = "", pool = "" }
  }
}
EOF
    return 0
  fi

  local cs_nas cs_root cs_hosts s_sched s_h s_d s_m r_nas r_pool
  cs_nas=$(yq -r '.storage.cluster_state.nas // ""' "$BOOTSTRAP" 2>/dev/null)
  cs_root=$(yq -r '.storage.cluster_state.dataset_root // "nomad"' "$BOOTSTRAP" 2>/dev/null)
  cs_hosts=$(yq -r '.storage.cluster_state.allow_hosts // ""' "$BOOTSTRAP" 2>/dev/null)
  s_sched=$(yq -r '.storage.snapshots.schedule // "hourly"' "$BOOTSTRAP" 2>/dev/null)
  s_h=$(yq -r '.storage.snapshots.retention_hourly // 96' "$BOOTSTRAP" 2>/dev/null)
  s_d=$(yq -r '.storage.snapshots.retention_daily // 30' "$BOOTSTRAP" 2>/dev/null)
  s_m=$(yq -r '.storage.snapshots.retention_monthly // 12' "$BOOTSTRAP" 2>/dev/null)
  r_nas=$(yq -r '.storage.snapshots.replicate_to.nas // ""' "$BOOTSTRAP" 2>/dev/null)
  r_pool=$(yq -r '.storage.snapshots.replicate_to.pool // ""' "$BOOTSTRAP" 2>/dev/null)

  cat <<EOF
nas_storage = {
  cluster_state = { nas = "$cs_nas", dataset_root = "$cs_root", allow_hosts = "$cs_hosts" }
  snapshots = {
    schedule          = "$s_sched"
    retention_hourly  = $s_h
    retention_daily   = $s_d
    retention_monthly = $s_m
    replicate_to      = { nas = "$r_nas", pool = "$r_pool" }
  }
}
EOF
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

  # Preserve every user/menu-managed toggle that isn't derived from
  # bootstrap.yml. If we don't carry these forward, Terraform sees the
  # variable defaults (false for deploy_*, "" for tokens) on the next
  # apply and DESTROYS every resource gated on them — including
  # vault_kv_secret_v2 and random_password instances, which means lost
  # service passwords. (Hard-learned 2026-05-01.)
  _preserve_bool() {
    local key="$1" default="$2" val=""
    if [ -f "$SERVICES_TFVARS" ]; then
      val=$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*\\([a-z]*\\).*/\\1/p" "$SERVICES_TFVARS" 2>/dev/null | head -1)
    fi
    [ -z "$val" ] && val="$default"
    echo "$val"
  }
  _preserve_str() {
    local key="$1" default="$2" val=""
    if [ -f "$SERVICES_TFVARS" ]; then
      val=$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\(.*\\)\"/\\1/p" "$SERVICES_TFVARS" 2>/dev/null | head -1)
    fi
    [ -z "$val" ] && val="$default"
    echo "$val"
  }

  local PREV_DEPLOY_TRAEFIK PREV_DEPLOY_DNS_RECORDS
  local PREV_DEPLOY_AUTHENTIK PREV_DEPLOY_SAMBA_AD PREV_DEPLOY_LAM
  local PREV_DEPLOY_UPTIME_KUMA PREV_DEPLOY_NETBOX PREV_DEPLOY_TAILSCALE PREV_DEPLOY_BACKUP
  local PREV_CFG_AUTH PREV_CFG_NETBOX PREV_NETBOX_TOKEN
  # deploy_traefik / deploy_dns_records default to true on first deploy
  # (Traefik is mandatory for the lab to work; DNS records are written
  # immediately so the cluster is reachable). After that, never let them
  # silently flip — same destructive footgun as the deploy_authentik bug.
  PREV_DEPLOY_TRAEFIK=$(_preserve_bool   "deploy_traefik"     "true")
  PREV_DEPLOY_DNS_RECORDS=$(_preserve_bool "deploy_dns_records" "true")
  PREV_DEPLOY_AUTHENTIK=$(_preserve_bool "deploy_authentik"   "false")
  PREV_DEPLOY_SAMBA_AD=$(_preserve_bool  "deploy_samba_ad"    "false")
  PREV_DEPLOY_LAM=$(_preserve_bool       "deploy_lam"         "false")
  PREV_DEPLOY_UPTIME_KUMA=$(_preserve_bool "deploy_uptime_kuma" "false")
  PREV_DEPLOY_NETBOX=$(_preserve_bool    "deploy_netbox"      "false")
  PREV_DEPLOY_TAILSCALE=$(_preserve_bool "deploy_tailscale"   "false")
  PREV_DEPLOY_BACKUP=$(_preserve_bool    "deploy_backup"      "false")
  PREV_CFG_AUTH=$(_preserve_bool         "configure_authentik" "false")
  PREV_CFG_NETBOX=$(_preserve_bool       "configure_netbox"    "false")
  PREV_NETBOX_TOKEN=$(_preserve_str      "netbox_api_token"    "not-configured")

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

# Service deploy toggles — preserved across re-runs. NEVER let these
# silently fall back to defaults; doing so destroys vault_kv_secret_v2
# resources and the random_password values backing them, taking down
# Authentik/Samba/etc.
deploy_traefik     = ${PREV_DEPLOY_TRAEFIK}
deploy_dns_records = ${PREV_DEPLOY_DNS_RECORDS}
deploy_authentik   = ${PREV_DEPLOY_AUTHENTIK}
deploy_samba_ad    = ${PREV_DEPLOY_SAMBA_AD}
deploy_lam         = ${PREV_DEPLOY_LAM}
deploy_uptime_kuma = ${PREV_DEPLOY_UPTIME_KUMA}
deploy_netbox      = ${PREV_DEPLOY_NETBOX}
deploy_tailscale   = ${PREV_DEPLOY_TAILSCALE}
deploy_backup      = ${PREV_DEPLOY_BACKUP}

# Two-phase configure toggles
configure_authentik = ${PREV_CFG_AUTH}
configure_netbox    = ${PREV_CFG_NETBOX}
netbox_api_token    = "${PREV_NETBOX_TOKEN}"

# Roaming profiles (from bootstrap.yml)
profile_server       = "$(yq -r '.profile_server // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
profile_share        = "$(yq -r '.profile_share // "profiles"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "profiles")"
profile_drive_letter = "$(yq -r '.profile_drive_letter // "P"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "P")"

# NAS servers (from bootstrap.yml)
$(generateNASServersTfvars)

# NAS storage role bindings (from bootstrap.yml storage.cluster_state + storage.snapshots)
$(generateNASStorageTfvars)

# UniFi Controller (from bootstrap.yml)
unifi_address = "$(yq -r '.unifi_address // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
unifi_api_key = "$(yq -r '.unifi_api_key // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
unifi_site    = "$(yq -r '.unifi_site // "default"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "default")"

# Periodic Backups (from bootstrap.yml)
backup_type         = "$(yq -r '.backup.type // "nfs"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "nfs")"
backup_nfs_server   = "$(yq -r '.backup.nfs_server // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
backup_nfs_path     = "$(yq -r '.backup.nfs_path // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
backup_smb_server   = "$(yq -r '.backup.smb_server // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
backup_smb_share    = "$(yq -r '.backup.smb_share // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
backup_smb_user     = "$(yq -r '.backup.smb_user // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
backup_smb_password = "$(yq -r '.backup.smb_password // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
backup_cron           = "$(yq -r '.backup.cron // "0 2 * * *"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "0 2 * * *")"
backup_timezone       = "$(yq -r '.backup.timezone // "UTC"' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo "UTC")"
backup_retention_days = $(yq -r '.backup.retention_days // 7' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || echo 7)

# Tailscale subnet routers (from bootstrap.yml). auth_key goes into
# Vault at secret/data/tailscale; advertise_routes defaults to network_cidr
# (terraform 'coalesce' falls back automatically if left empty here).
tailscale_auth_key         = "$(yq -r '.tailscale.auth_key // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"
tailscale_advertise_routes = "$(yq -r '.tailscale.advertise_routes // ""' "${SCRIPT_DIR}/bootstrap.yml" 2>/dev/null || true)"

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

    # Normal path: credentials file exists, unseal with saved key.
    # Read .sealed directly — `// true` would coalesce a real false
    # (Vault unsealed) to "true" because jq's `//` is null-OR-false.
    local IS_SEALED
    IS_SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed' 2>/dev/null)
    [ -z "$IS_SEALED" ] || [ "$IS_SEALED" = "null" ] && IS_SEALED="true"

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
