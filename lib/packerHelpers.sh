#!/usr/bin/env bash

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
