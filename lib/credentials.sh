#!/usr/bin/env bash

# credentials.sh - Password generation and management utilities
#
# This module provides functions for generating strong random passwords
# and managing service credentials stored in crypto/service-passwords.json.
#
# Generated passwords use cryptographically secure random bytes from OpenSSL
# and include mixed character types for improved security.

# Generate a strong random password
# Arguments:
#   $1 - length (optional, default: 24)
# Returns: Password string (alphanumeric + special chars)
function generatePassword() {
  local length="${1:-24}"
  # Generate extra bytes to account for filtering, then take exact length
  openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c "$length"
}

# Generate and save all service passwords to crypto/service-passwords.json
# This function is idempotent - it will not regenerate existing passwords.
#
# Globals read: CRYPTO_DIR
# Arguments: None
# Returns: 0 on success
#
# Side effects:
#   - Creates crypto/service-passwords.json with 600 permissions
function generateServicePasswords() {
  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"

  # Don't regenerate if file exists (idempotent)
  if [ -f "$PASSWORDS_FILE" ]; then
    info "Service passwords already exist at $PASSWORDS_FILE"
    return 0
  fi

  # Ensure crypto directory exists
  mkdir -p "$CRYPTO_DIR"

  doing "Generating service passwords..."

  local PIHOLE_ADMIN=$(generatePassword 20)
  local PIHOLE_ROOT=$(generatePassword 20)
  local KASM_ADMIN=$(generatePassword 20)
  local AUTHENTIK_ADMIN=$(generatePassword 24)
  local PACKER_ROOT=$(generatePassword 16)
  local PACKER_SSH=$(generatePassword 16)
  local TEMPLATE_PASS=$(generatePassword 16)

  jq -n \
    --arg pihole_admin "$PIHOLE_ADMIN" \
    --arg pihole_root "$PIHOLE_ROOT" \
    --arg kasm_admin "$KASM_ADMIN" \
    --arg authentik_admin "$AUTHENTIK_ADMIN" \
    --arg packer_root "$PACKER_ROOT" \
    --arg packer_ssh "$PACKER_SSH" \
    --arg template_pass "$TEMPLATE_PASS" \
    '{
      pihole_admin_password: $pihole_admin,
      pihole_root_password: $pihole_root,
      kasm_admin_password: $kasm_admin,
      authentik_admin_password: $authentik_admin,
      packer_root_password: $packer_root,
      packer_ssh_password: $packer_ssh,
      template_password: $template_pass,
      generated_at: (now | todate)
    }' > "$PASSWORDS_FILE"

  chmod 600 "$PASSWORDS_FILE"
  success "Service passwords saved to $PASSWORDS_FILE"
}

# Load passwords from file into environment variables
# Must call generateServicePasswords first if passwords don't exist.
#
# Globals read: CRYPTO_DIR
# Globals modified: PIHOLE_ADMIN_PASSWORD, PIHOLE_ROOT_PASSWORD,
#                   KASM_ADMIN_PASSWORD, PACKER_ROOT_PASSWORD, PACKER_SSH_PASSWORD
# Arguments: None
# Returns: 0 on success, 1 if passwords file not found
function loadServicePasswords() {
  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"

  if [ ! -f "$PASSWORDS_FILE" ]; then
    error "Service passwords file not found at $PASSWORDS_FILE"
    error "Run generateServicePasswords first or re-run setup."
    return 1
  fi

  PIHOLE_ADMIN_PASSWORD=$(jq -r '.pihole_admin_password' "$PASSWORDS_FILE")
  PIHOLE_ROOT_PASSWORD=$(jq -r '.pihole_root_password' "$PASSWORDS_FILE")
  KASM_ADMIN_PASSWORD=$(jq -r '.kasm_admin_password' "$PASSWORDS_FILE")
  AUTHENTIK_ADMIN_PASSWORD=$(jq -r '.authentik_admin_password // ""' "$PASSWORDS_FILE")
  PACKER_ROOT_PASSWORD=$(jq -r '.packer_root_password' "$PASSWORDS_FILE")
  PACKER_SSH_PASSWORD=$(jq -r '.packer_ssh_password' "$PASSWORDS_FILE")
  TEMPLATE_PASSWORD=$(jq -r '.template_password // ""' "$PASSWORDS_FILE")

  export PIHOLE_ADMIN_PASSWORD PIHOLE_ROOT_PASSWORD
  export KASM_ADMIN_PASSWORD AUTHENTIK_ADMIN_PASSWORD PACKER_ROOT_PASSWORD PACKER_SSH_PASSWORD TEMPLATE_PASSWORD
}

# Check if service passwords have been generated
# Arguments: None
# Returns: 0 if passwords exist, 1 if not
function hasServicePasswords() {
  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"
  [ -f "$PASSWORDS_FILE" ]
}

# Sync local secrets (service passwords + SSH keys) into Vault KV.
# This makes Vault the single source of truth for all credentials.
# Idempotent — overwrites existing entries with current local values.
#
# Writes:
#   secret/services/pihole    - admin_password, root_password
#   secret/services/kasm      - admin_password
#   secret/services/packer    - root_password, ssh_password, template_password
#   secret/services/ssh-keys  - labadmin (private), labadmin_pub (public),
#                               enterprise (private), enterprise_pub (public)
#
# Globals read: CRYPTO_DIR, VAULT_CREDENTIALS_FILE
# Arguments: None
# Returns: 0 on success, 1 on failure
function syncSecretsToVault() {
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials file not found — deploy Vault first"
    return 1
  fi

  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ] || [ -z "$ROOT_TOKEN" ]; then
    error "Could not read Vault credentials"
    return 1
  fi

  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"
  if [ ! -f "$PASSWORDS_FILE" ]; then
    error "Service passwords file not found at $PASSWORDS_FILE"
    return 1
  fi

  doing "Syncing service passwords to Vault KV..."

  # Pi-hole
  local PIHOLE_PAYLOAD
  PIHOLE_PAYLOAD=$(jq -n \
    --arg admin "$(jq -r '.pihole_admin_password' "$PASSWORDS_FILE")" \
    --arg root "$(jq -r '.pihole_root_password' "$PASSWORDS_FILE")" \
    '{data: {admin_password: $admin, root_password: $root}}')

  if curl -skf -X POST "${VAULT_ADDR}/v1/secret/data/services/pihole" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PIHOLE_PAYLOAD" > /dev/null; then
    success "  secret/services/pihole"
  else
    warn "  Failed to write secret/services/pihole"
  fi

  # Kasm
  local KASM_PAYLOAD
  KASM_PAYLOAD=$(jq -n \
    --arg admin "$(jq -r '.kasm_admin_password' "$PASSWORDS_FILE")" \
    '{data: {admin_password: $admin}}')

  if curl -skf -X POST "${VAULT_ADDR}/v1/secret/data/services/kasm" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$KASM_PAYLOAD" > /dev/null; then
    success "  secret/services/kasm"
  else
    warn "  Failed to write secret/services/kasm"
  fi

  # Packer
  local PACKER_PAYLOAD
  PACKER_PAYLOAD=$(jq -n \
    --arg root "$(jq -r '.packer_root_password' "$PASSWORDS_FILE")" \
    --arg ssh "$(jq -r '.packer_ssh_password' "$PASSWORDS_FILE")" \
    --arg template "$(jq -r '.template_password' "$PASSWORDS_FILE")" \
    '{data: {root_password: $root, ssh_password: $ssh, template_password: $template}}')

  if curl -skf -X POST "${VAULT_ADDR}/v1/secret/data/services/packer" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PACKER_PAYLOAD" > /dev/null; then
    success "  secret/services/packer"
  else
    warn "  Failed to write secret/services/packer"
  fi

  # SSH keys — store both key pairs for disaster recovery
  doing "Syncing SSH keys to Vault KV..."

  local SSH_PAYLOAD
  SSH_PAYLOAD=$(jq -n \
    --arg labadmin "$(cat "$CRYPTO_DIR/labadmin" 2>/dev/null || echo "")" \
    --arg labadmin_pub "$(cat "$CRYPTO_DIR/labadmin.pub" 2>/dev/null || echo "")" \
    --arg enterprise "$(cat "$CRYPTO_DIR/labenterpriseadmin" 2>/dev/null || echo "")" \
    --arg enterprise_pub "$(cat "$CRYPTO_DIR/labenterpriseadmin.pub" 2>/dev/null || echo "")" \
    '{data: {labadmin: $labadmin, labadmin_pub: $labadmin_pub, enterprise: $enterprise, enterprise_pub: $enterprise_pub}}')

  if curl -skf -X POST "${VAULT_ADDR}/v1/secret/data/services/ssh-keys" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$SSH_PAYLOAD" > /dev/null; then
    success "  secret/services/ssh-keys"
  else
    warn "  Failed to write secret/services/ssh-keys"
  fi

  # Cluster configuration — used by Nomad jobs (samba-dc, lam) via Vault templates
  doing "Writing cluster config to Vault KV..."

  local CLUSTER_PAYLOAD
  local DNS_POSTFIX_VAL=""
  local DNS_SERVER_VAL=""
  local NETWORK_CIDR_VAL=""
  local GATEWAY_VAL=""

  if [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX_VAL=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    NETWORK_CIDR_VAL=$(jq -r '.network.external.cidr // ""' "$CLUSTER_INFO_FILE")
    GATEWAY_VAL=$(jq -r '.network.external.gateway // ""' "$CLUSTER_INFO_FILE")
  fi
  # Fall back to global var if cluster-info.json doesn't have it
  DNS_POSTFIX_VAL="${DNS_POSTFIX_VAL:-${DNS_POSTFIX:-}}"

  # DNS server: use HA VIP if enabled, otherwise first DNS node IP
  if [ -f "$CLUSTER_INFO_FILE" ] && jq -e '.network.external.ha_enabled == true' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    DNS_SERVER_VAL=$(jq -r '.network.external.ha_vip // ""' "$CLUSTER_INFO_FILE")
  fi
  if [ -z "$DNS_SERVER_VAL" ] && [ -f "hosts.json" ]; then
    DNS_SERVER_VAL=$(jq -r '.external[0].ip // ""' hosts.json | sed 's|/.*||')
  fi

  # AD-related values (populated if Samba AD is configured, empty otherwise)
  local AD_REALM="" AD_DOMAIN="" AD_REALM_LOWER="" BASE_DN="" DNS_FORWARDER=""
  if [ -n "$DNS_POSTFIX_VAL" ]; then
    AD_REALM="AD.$(echo "$DNS_POSTFIX_VAL" | tr '[:lower:]' '[:upper:]')"
    AD_DOMAIN="AD"
    AD_REALM_LOWER="ad.${DNS_POSTFIX_VAL}"
    BASE_DN="DC=ad,$(echo "$DNS_POSTFIX_VAL" | sed 's/\./,DC=/g' | sed 's/^/DC=/')"
    DNS_FORWARDER="${DNS_SERVER_VAL:-${GATEWAY_VAL}}"
  fi

  CLUSTER_PAYLOAD=$(jq -n \
    --arg dns_postfix "$DNS_POSTFIX_VAL" \
    --arg dns_server "$DNS_SERVER_VAL" \
    --arg network_cidr "$NETWORK_CIDR_VAL" \
    --arg gateway "$GATEWAY_VAL" \
    --arg ad_realm "$AD_REALM" \
    --arg ad_domain "$AD_DOMAIN" \
    --arg ad_realm_lower "$AD_REALM_LOWER" \
    --arg base_dn "$BASE_DN" \
    --arg dns_forwarder "$DNS_FORWARDER" \
    '{data: {dns_postfix: $dns_postfix, dns_server: $dns_server, network_cidr: $network_cidr, gateway: $gateway, ad_realm: $ad_realm, ad_domain: $ad_domain, ad_realm_lower: $ad_realm_lower, base_dn: $base_dn, dns_forwarder: $dns_forwarder}}')

  if curl -skf -X POST "${VAULT_ADDR}/v1/secret/data/config/cluster" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$CLUSTER_PAYLOAD" > /dev/null; then
    success "  secret/config/cluster"
  else
    warn "  Failed to write secret/config/cluster"
  fi

  # Nomad node IPs — used by samba-dc and lam jobs via Vault templates
  local NOMAD_NODES_PAYLOAD="{\"data\":{"
  local node_idx=1
  if [ -f "hosts.json" ]; then
    while IFS= read -r line; do
      local hostname ip
      hostname=$(echo "$line" | jq -r '.hostname')
      ip=$(echo "$line" | jq -r '.ip')
      [ $node_idx -gt 1 ] && NOMAD_NODES_PAYLOAD+=","
      NOMAD_NODES_PAYLOAD+="\"${hostname}_ip\":\"${ip}\""
      node_idx=$((node_idx + 1))
    done < <(jq -c '.external[] | select(.hostname | startswith("nomad"))' hosts.json 2>/dev/null)
  fi
  NOMAD_NODES_PAYLOAD+="}}"

  if curl -skf -X POST "${VAULT_ADDR}/v1/secret/data/config/nomad-nodes" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$NOMAD_NODES_PAYLOAD" > /dev/null; then
    success "  secret/config/nomad-nodes"
  else
    warn "  Failed to write secret/config/nomad-nodes"
  fi

  success "Secrets synced to Vault"
}
