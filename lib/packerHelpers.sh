# Verifies a Packer template exists
# Parameters: vmid, template_name
function ensureTemplate() {
  local vmid="$1"
  local template_name="$2"

  doing "Checking for $template_name (VM $vmid)..."
  if ! sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $vmid" &>/dev/null; then
    error "$template_name (VM $vmid) not found!"
    return 1
  fi
  success "$template_name found"
  return 0
}

# Updates Packer config with current storage settings (legacy - use updatePackerFromClusterInfo)
function updatePackerStorageConfig() {
  local config="packer/packer.auto.pkrvars.hcl"
  if [ -f "$config" ]; then
    doing "Updating Packer storage config..."
    grep -v "^template_storage" "$config" > "${config}.tmp" || true
    mv "${config}.tmp" "$config"
    echo "template_storage = \"$TEMPLATE_STORAGE\"" >> "$config"
    echo "template_storage_type = \"$TEMPLATE_STORAGE_TYPE\"" >> "$config"
    success "Packer config updated: storage=$TEMPLATE_STORAGE, type=$TEMPLATE_STORAGE_TYPE"
  else
    warn "Packer config not found at $config"
  fi
}

# Updates Packer config from cluster-info.json and proxmox-credentials.json
function updatePackerFromClusterInfo() {
  doing "Updating packer.auto.pkrvars.hcl from cluster configuration..."

  local PACKER_FILE="packer/packer.auto.pkrvars.hcl"
  local PACKER_EXAMPLE="packer/packer.auto.pkrvars.hcl.example"
  local CREDS_FILE="$CRYPTO_DIR/proxmox-credentials.json"

  # Check if cluster-info.json exists
  if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    error "cluster-info.json not found. Run setup again."
    return 1
  fi

  # Copy from example if doesn't exist
  if [ ! -f "$PACKER_FILE" ]; then
    if [ -f "$PACKER_EXAMPLE" ]; then
      cp "$PACKER_EXAMPLE" "$PACKER_FILE"
      info "Created packer.auto.pkrvars.hcl from example"
    else
      error "packer.auto.pkrvars.hcl.example not found"
      return 1
    fi
  fi

  # Load values from cluster-info.json
  local DNS_POSTFIX_VAL=$(jq -r '.dns_postfix // "lab.lan"' "$CLUSTER_INFO_FILE")
  local STORAGE_VAL=$(jq -r '.storage.selected // "local-lvm"' "$CLUSTER_INFO_FILE")
  local STORAGE_TYPE_VAL=$(jq -r '.storage.type // "lvm"' "$CLUSTER_INFO_FILE")
  local PRIMARY_NODE=$(jq -r '.nodes[0].name // "pve"' "$CLUSTER_INFO_FILE")
  local PRIMARY_IP=$(jq -r '.nodes[0].ip // ""' "$CLUSTER_INFO_FILE")

  # Load API credentials if available
  local API_URL="" API_TOKEN_ID="" API_TOKEN_SECRET=""
  if [ -f "$CREDS_FILE" ]; then
    API_URL=$(jq -r '.proxmox_api_url // ""' "$CREDS_FILE")
    API_TOKEN_ID=$(jq -r '.proxmox_api_token_id // ""' "$CREDS_FILE")
    API_TOKEN_SECRET=$(jq -r '.proxmox_api_token_secret // ""' "$CREDS_FILE")
  fi

  # Helper function for cross-platform sed
  sed_inplace() {
    if sed --version >/dev/null 2>&1; then
      sed -i "$@"
    else
      sed -i '' "$@"
    fi
  }

  # Update Proxmox API credentials
  if [ -n "$API_URL" ] && [ -n "$API_TOKEN_ID" ] && [ -n "$API_TOKEN_SECRET" ] && \
     [ "$API_TOKEN_SECRET" != "RETRIEVE_FROM_PROXMOX_OR_REGENERATE" ] && \
     [ "$API_TOKEN_SECRET" != "PASTE_TOKEN_SECRET_HERE" ]; then
    sed_inplace "s|^proxmox_url[[:space:]]*=.*|proxmox_url = \"$API_URL\"|" "$PACKER_FILE"
    sed_inplace "s|^proxmox_token_id[[:space:]]*=.*|proxmox_token_id = \"$API_TOKEN_ID\"|" "$PACKER_FILE"
    sed_inplace "s|^proxmox_token_secret[[:space:]]*=.*|proxmox_token_secret = \"$API_TOKEN_SECRET\"|" "$PACKER_FILE"
    info "  proxmox_url = \"$API_URL\""
    info "  proxmox_token_id = \"$API_TOKEN_ID\""
    info "  proxmox_token_secret = \"<set from credentials>\""
  else
    warn "  Proxmox API credentials not available - update packer config manually"
  fi

  # Update proxmox_node
  sed_inplace "s|^proxmox_node[[:space:]]*=.*|proxmox_node = \"$PRIMARY_NODE\"|" "$PACKER_FILE"
  info "  proxmox_node = \"$PRIMARY_NODE\""

  # Update dns_postfix
  sed_inplace "s|^dns_postfix[[:space:]]*=.*|dns_postfix = \"$DNS_POSTFIX_VAL\"|" "$PACKER_FILE"
  info "  dns_postfix = \"$DNS_POSTFIX_VAL\""

  # Update template_storage
  sed_inplace "s|^template_storage[[:space:]]*=.*|template_storage = \"$STORAGE_VAL\"|" "$PACKER_FILE"
  info "  template_storage = \"$STORAGE_VAL\""

  # Update template_storage_type
  sed_inplace "s|^template_storage_type[[:space:]]*=.*|template_storage_type = \"$STORAGE_TYPE_VAL\"|" "$PACKER_FILE"
  info "  template_storage_type = \"$STORAGE_TYPE_VAL\""

  # Load and apply packer passwords from crypto/service-passwords.json
  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"
  if [ -f "$PASSWORDS_FILE" ]; then
    local PACKER_ROOT=$(jq -r '.packer_root_password' "$PASSWORDS_FILE")
    local PACKER_SSH=$(jq -r '.packer_ssh_password' "$PASSWORDS_FILE")

    sed_inplace "s|^root_password[[:space:]]*=.*|root_password = \"$PACKER_ROOT\"|" "$PACKER_FILE"
    sed_inplace "s|^ssh_password[[:space:]]*=.*|ssh_password = \"$PACKER_SSH\"|" "$PACKER_FILE"

    info "  Packer passwords populated from $PASSWORDS_FILE"
  else
    warn "  Service passwords file not found - packer passwords not auto-populated"
  fi

  success "Packer configuration updated from cluster-info.json"
}