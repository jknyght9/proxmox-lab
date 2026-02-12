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

# Updates Packer config with current storage settings
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