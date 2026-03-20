#!/usr/bin/env bash

# Generic LXC template creation function
# Parameters: VMID, template name, install script path, storage, bridge, cores, memory
function createLXCTemplate() {
  local TEMPLATE_VMID="$1"
  local TEMPLATE_NAME="$2"
  local INSTALL_SCRIPT="$3"
  local STORAGE="${4:-local-lvm}"
  local BRIDGE="${5:-vmbr0}"
  local CORES="${6:-2}"
  local MEMORY="${7:-2048}"

  doing "Creating LXC template: ${TEMPLATE_NAME} (VMID: ${TEMPLATE_VMID})"
  scpTo "$INSTALL_SCRIPT" "$REMOTE_USER" "$PROXMOX_HOST" "/root/install.sh"

  doing "Creating LXC container ${TEMPLATE_VMID} (${TEMPLATE_NAME})..."
  local OSTEMPLATE
  OSTEMPLATE=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "pveam list local | awk '/vztmpl/ {print \$1; exit}'")
  echo "$OSTEMPLATE"
  # Copy admin public key to Proxmox node first (for VM/container access)
  scpTo "$ADMIN_PUBKEY_PATH" "$REMOTE_USER" "$PROXMOX_HOST" "/root/.ssh/$ADMIN_KEY_NAME.pub"

  # Note: Using raw ssh here because we need -t for interactive operations
  # Use enterprise key to SSH to Proxmox, but install admin key into the container
  ssh -i "$ENTERPRISE_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t "$REMOTE_USER@$PROXMOX_HOST" "\
    pct stop ${TEMPLATE_VMID} || true > /dev/null 2>&1 && pct destroy ${TEMPLATE_VMID} || true > /dev/null 2>&1
    pct create ${TEMPLATE_VMID} ${OSTEMPLATE} \
      --storage ${STORAGE} \
      --hostname ${TEMPLATE_NAME} \
      --cores ${CORES} \
      --memory ${MEMORY} \
      --net0 name=eth0,bridge=${BRIDGE},ip=dhcp \
      --start
    pct set ${TEMPLATE_VMID} -features nesting=1,keyctl=1
    pct exec ${TEMPLATE_VMID} -- bash -c '
      mkdir -p /root/.ssh &&
      chmod 700 /root/.ssh &&
      touch /root/.ssh/authorized_keys &&
      chmod 600 /root/.ssh/authorized_keys'
    pct push ${TEMPLATE_VMID} /root/.ssh/$ADMIN_KEY_NAME.pub /root/$ADMIN_KEY_NAME.pub
    pct exec ${TEMPLATE_VMID} -- bash -c 'cat /root/$ADMIN_KEY_NAME.pub >> /root/.ssh/authorized_keys && rm /root/$ADMIN_KEY_NAME.pub'
    pct reboot ${TEMPLATE_VMID}"

  doing "Running installation script..."
  sshRun "$REMOTE_USER" "$PROXMOX_HOST" "pct push ${TEMPLATE_VMID} /root/install.sh /root/install.sh && pct exec ${TEMPLATE_VMID} -- bash -c 'bash /root/install.sh'" || true

  doing "Cleaning container for template..."
  sshRun "$REMOTE_USER" "$PROXMOX_HOST" "pct exec ${TEMPLATE_VMID} -- bash -c 'apt-get clean && rm -rf /tmp/* /var/tmp/* /var/log/* /root/.bash_history && truncate -s 0 /etc/machine-id && rm -f /etc/ssh/ssh_host_* && ssh-keygen -A && systemctl enable ssh'"

  doing "Stopping container and converting to template..."
  sshRun "$REMOTE_USER" "$PROXMOX_HOST" "pct stop ${TEMPLATE_VMID} && pct template ${TEMPLATE_VMID} && pct set ${TEMPLATE_VMID} -ostype debian"
  success "LXC template '${TEMPLATE_NAME}' created successfully"
}

function ensureLXCTemplates() {
  doing "Ensuring LXC templates are available on all cluster nodes..."

  local TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"
  local failed_nodes=()

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Check if template exists on this node
    if sshRun "$REMOTE_USER" "$ip" "test -f /var/lib/vz/template/cache/${TEMPLATE}" 2>/dev/null; then
      info "  $node: Template already exists"
    else
      doing "  $node: Downloading template..."
      if sshRun "$REMOTE_USER" "$ip" "pveam update && pveam download local ${TEMPLATE}" 2>/dev/null; then
        success "  $node: Template downloaded"
      else
        failed_nodes+=("$node ($ip)")
      fi
    fi
  done

  if [ ${#failed_nodes[@]} -gt 0 ]; then
    error "Failed to download template on the following nodes:"
    for node in "${failed_nodes[@]}"; do
      echo "  - $node"
    done
    return 1
  fi

  success "LXC templates available on all nodes"
  return 0
}

# Migrates a template disk to the appropriate storage based on deployment type
# Parameters: vmid
# NOTE: Packer proxmox-clone builder does NOT support specifying target storage for cloned disks.
#       Adding a "disks" block in Packer ADDS a new disk instead of configuring the cloned disk.
#       This function must be called AFTER Packer build to move the disk to the correct storage.
#       - For clusters: moves to selected shared storage (TEMPLATE_STORAGE)
#       - For single-node: moves to local-lvm
function migrateTemplateToSharedStorage() {
  local vmid="$1"

  # Determine target storage based on deployment type
  local target_storage
  if [ "$IS_CLUSTER" = "true" ] && [ "$USE_SHARED_STORAGE" = "true" ]; then
    target_storage="$TEMPLATE_STORAGE"
  else
    target_storage="local-lvm"
  fi

  doing "Checking template $vmid disk location..."

  # Get current disk storage (format: "storage:volume,options")
  local disk_line
  disk_line=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $vmid 2>/dev/null | grep -E '^scsi0:'" || echo "")

  if [ -z "$disk_line" ]; then
    warn "Template $vmid not found or has no scsi0 disk, skipping migration"
    return 0
  fi

  # Extract storage name (everything after "scsi0: " and before ":")
  local current_storage
  current_storage=$(echo "$disk_line" | sed 's/^scsi0: *//' | cut -d: -f1)

  info "Current disk storage: $current_storage"
  info "Target storage: $target_storage"

  if [ "$current_storage" = "$target_storage" ]; then
    success "Template $vmid disk already on $target_storage"
    return 0
  fi

  doing "Moving template $vmid disk from $current_storage to $target_storage..."

  # Move the disk to target storage (--delete 1 removes the source after copy)
  local move_output
  move_output=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm move_disk $vmid scsi0 $target_storage --delete 1 2>&1")
  local move_result=$?

  if [ $move_result -eq 0 ]; then
    success "Template $vmid disk migrated to $target_storage"

    # Verify the move succeeded
    local new_disk_line
    new_disk_line=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $vmid 2>/dev/null | grep -E '^scsi0:'" || echo "")
    local new_storage
    new_storage=$(echo "$new_disk_line" | sed 's/^scsi0: *//' | cut -d: -f1)

    if [ "$new_storage" = "$target_storage" ]; then
      success "Verified: disk is now on $target_storage"
    else
      warn "Verification failed: disk appears to still be on $new_storage"
    fi
  else
    error "Failed to migrate template $vmid disk to $target_storage"
    error "Output: $move_output"
    return 1
  fi
  return 0
}

# Removes an existing template VM if it exists
# Parameters: vmid, template_name
function removeTemplateIfExists() {
  local vmid="$1"
  local template_name="${2:-template}"

  doing "Checking for existing $template_name (VM $vmid)..."
  if sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $vmid" &>/dev/null; then
    warn "$template_name (VM $vmid) already exists, removing..."
    sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm destroy $vmid --purge" || true
    success "Existing template removed"
  fi
}