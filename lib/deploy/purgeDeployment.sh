#!/usr/bin/env bash

# Complete purge - reset nodes to pre-install state
function purgeDeployment() {
  cat <<EOF

############################################################################
Complete Deployment Purge

This will COMPLETELY remove all lab infrastructure and reset Proxmox nodes
to their pre-install state:

  - All VMs and LXC containers
  - Packer templates (9001, 9002)
  - Cloud-init snippets (all .yml/.yaml files)
  - ACME certificates
  - Step-CA root certificate from trust store
  - DNS configuration
  - Hashicorp API user
  - SSH keys (removed last)
  - Local configuration files

This action cannot be undone.
#############################################################################

EOF

  read -rp "$(question "Are you sure? Type 'PURGE' to confirm: ")" CONFIRM
  if [[ "$CONFIRM" != "PURGE" ]]; then
    info "Purge cancelled"
    return 0
  fi

  # Load cluster info for multi-node cleanup
  if ! ensureClusterContext; then
    warn "No cluster info found. Attempting to proceed with single node..."
    if [ -z "$PROXMOX_HOST" ]; then
      read -rp "$(question "Enter Proxmox host IP: ")" PROXMOX_HOST
    fi
    CLUSTER_NODES=("$PROXMOX_HOST")
    CLUSTER_NODE_IPS=("$PROXMOX_HOST")
  fi

  echo
  warn "Starting complete deployment purge..."
  echo

  # Step 1: Purge all VMs, LXC containers, and Packer templates
  doing "Step 1/8: Purging all VMs, LXC containers, and templates..."
  purgeClusterResources --auto --include-templates || true

  # Step 2: Remove cloud-init snippets
  doing "Step 2/8: Removing cloud-init snippets..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Cleaning snippets on $node..."
    # Remove all cloud-init snippets (user-data, meta-data, network-config, vendor-data)
    sshRun "$REMOTE_USER" "$ip" "rm -f /var/lib/vz/snippets/*.yml /var/lib/vz/snippets/*.yaml 2>/dev/null" || true
  done
  success "Cloud-init snippets removed"

  # Step 3: Remove ACME certificates
  doing "Step 3/8: Removing ACME certificates..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing ACME config on $node..."
    sshRun "$REMOTE_USER" "$ip" "pvenode config set --delete acme 2>/dev/null; pvenode acme account deactivate 2>/dev/null" || true
  done
  success "ACME certificates removed"

  # Step 4: Remove step-ca root cert from trust store
  doing "Step 4/8: Removing step-ca root certificate from trust store..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing CA cert on $node..."
    sshRun "$REMOTE_USER" "$ip" "rm -f /usr/local/share/ca-certificates/step-ca-root.crt 2>/dev/null; update-ca-certificates 2>/dev/null" || true
  done
  success "Step-CA root certificate removed"

  # Step 5: Reset node DNS configuration
  doing "Step 5/8: Resetting DNS configuration..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Resetting DNS on $node..."
    sshRun "$REMOTE_USER" "$ip" "sed -i 's/^nameserver .*/nameserver 1.1.1.1/' /etc/resolv.conf 2>/dev/null" || true
  done
  success "DNS configuration reset"

  # Step 6: Remove hashicorp API user
  doing "Step 6/8: Removing hashicorp API user..."
  sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" "pveum user delete hashicorp@pam 2>/dev/null; pveum token delete hashicorp@pam hashicorp-token 2>/dev/null" || true
  success "Hashicorp API user removed"

  # Step 7: Clean local files
  doing "Step 7/8: Cleaning local configuration files..."
  rm -f hosts.json 2>/dev/null || true
  # Remove auto-generated sections from terraform.tfvars (keep manual config)
  if [ -f "terraform/terraform.tfvars" ]; then
    sed -i.bak '/# Proxmox cluster node IPs (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    sed -i.bak '/# DNS cluster nodes - Main cluster (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    sed -i.bak '/# DNS cluster nodes - Labnet SDN cluster (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    rm -f terraform/terraform.tfvars.bak 2>/dev/null || true
  fi
  # Remove storage config from cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local tmp=$(mktemp)
    jq 'del(.storage)' "$CLUSTER_INFO_FILE" > "$tmp" && mv "$tmp" "$CLUSTER_INFO_FILE"
  fi
  # Clean packer storage settings
  if [ -f "packer/packer.auto.pkrvars.hcl" ]; then
    grep -v "^template_storage" packer/packer.auto.pkrvars.hcl > packer/packer.auto.pkrvars.hcl.tmp 2>/dev/null || true
    mv packer/packer.auto.pkrvars.hcl.tmp packer/packer.auto.pkrvars.hcl 2>/dev/null || true
  fi
  # Clean terraform state
  docker compose run --rm -T terraform state list 2>/dev/null | while read -r resource; do
    docker compose run --rm -T terraform state rm "$resource" 2>/dev/null || true
  done
  success "Local files cleaned"

  # Step 8: Remove SSH keys (LAST - we need SSH for all previous steps!)
  doing "Step 8/8: Removing SSH keys from nodes..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing SSH key on $node..."
    # Get the public key content to remove from authorized_keys
    if [ -f "${KEY_PATH}.pub" ]; then
      local pubkey
      pubkey=$(cat "${KEY_PATH}.pub")
      sshRun "$REMOTE_USER" "$ip" "grep -v '$pubkey' /root/.ssh/authorized_keys > /tmp/ak_tmp && mv /tmp/ak_tmp /root/.ssh/authorized_keys" 2>/dev/null || true
    fi
  done
  success "SSH keys removed from nodes"

  echo
  success "Complete deployment purge finished!"
  warn "You may want to delete the local crypto/ directory if you no longer need the SSH keys."
  warn "You may also want to delete cluster-info.json to start fresh."
}