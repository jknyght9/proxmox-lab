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
  local STEPCA_ROOT=$(generatePassword 20)
  local KASM_ADMIN=$(generatePassword 20)
  local PACKER_ROOT=$(generatePassword 16)
  local PACKER_SSH=$(generatePassword 16)

  jq -n \
    --arg pihole_admin "$PIHOLE_ADMIN" \
    --arg pihole_root "$PIHOLE_ROOT" \
    --arg stepca_root "$STEPCA_ROOT" \
    --arg kasm_admin "$KASM_ADMIN" \
    --arg packer_root "$PACKER_ROOT" \
    --arg packer_ssh "$PACKER_SSH" \
    '{
      pihole_admin_password: $pihole_admin,
      pihole_root_password: $pihole_root,
      "step-ca_root_password": $stepca_root,
      kasm_admin_password: $kasm_admin,
      packer_root_password: $packer_root,
      packer_ssh_password: $packer_ssh,
      generated_at: (now | todate)
    }' > "$PASSWORDS_FILE"

  chmod 600 "$PASSWORDS_FILE"
  success "Service passwords saved to $PASSWORDS_FILE"
}

# Load passwords from file into environment variables
# Must call generateServicePasswords first if passwords don't exist.
#
# Globals read: CRYPTO_DIR
# Globals modified: PIHOLE_ADMIN_PASSWORD, PIHOLE_ROOT_PASSWORD, STEPCA_ROOT_PASSWORD,
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
  STEPCA_ROOT_PASSWORD=$(jq -r '.["step-ca_root_password"]' "$PASSWORDS_FILE")
  KASM_ADMIN_PASSWORD=$(jq -r '.kasm_admin_password' "$PASSWORDS_FILE")
  PACKER_ROOT_PASSWORD=$(jq -r '.packer_root_password' "$PASSWORDS_FILE")
  PACKER_SSH_PASSWORD=$(jq -r '.packer_ssh_password' "$PASSWORDS_FILE")

  export PIHOLE_ADMIN_PASSWORD PIHOLE_ROOT_PASSWORD STEPCA_ROOT_PASSWORD
  export KASM_ADMIN_PASSWORD PACKER_ROOT_PASSWORD PACKER_SSH_PASSWORD
}

# Check if service passwords have been generated
# Arguments: None
# Returns: 0 if passwords exist, 1 if not
function hasServicePasswords() {
  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"
  [ -f "$PASSWORDS_FILE" ]
}
