#!/usr/bin/env bash

# Complete purge - reset nodes to pre-install state
function purgeDeployment() {
  cat <<EOF

############################################################################
Complete Deployment Purge

This will COMPLETELY remove all lab infrastructure and reset Proxmox nodes
to their pre-install state:

  - All VMs and LXC containers
  - Packer templates (9001, 9002) - NOT base cloud images (9997-9999)
  - Cloud-init snippets (all .yml/.yaml files)
  - ACME certificates
  - Step-CA root certificate from trust store
  - DNS configuration (resolv.conf reset)
  - Hashicorp API user and HashicorpBuild role
  - Labnet SDN (zone, vnet, subnets, iptables SNAT rules)
  - Tailscale DNS override (re-enables MagicDNS)
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
  doing "Step 1/10: Purging all VMs, LXC containers, and templates..."
  purgeClusterResources --auto --include-templates || true

  # Step 2: Remove cloud-init snippets
  doing "Step 2/10: Removing cloud-init snippets..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Cleaning snippets on $node..."
    # Remove all cloud-init snippets (user-data, meta-data, network-config, vendor-data)
    sshRun "$REMOTE_USER" "$ip" "rm -f /var/lib/vz/snippets/*.yml /var/lib/vz/snippets/*.yaml 2>/dev/null" || true
  done
  success "Cloud-init snippets removed"

  # Step 3: Remove ACME certificates
  # Note: We only delete local config, not deactivate the account (which requires CA connectivity)
  doing "Step 3/10: Removing ACME certificates..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing ACME config on $node..."
    # Delete ACME config and account files locally (don't try to contact CA)
    sshRun "$REMOTE_USER" "$ip" "pvenode config set --delete acme 2>/dev/null; rm -f /etc/pve/priv/acme/* 2>/dev/null" || true
  done
  success "ACME certificates removed"

  # Step 4: Remove step-ca root cert from trust store
  doing "Step 4/10: Removing step-ca root certificate from trust store..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing CA cert on $node..."
    sshRun "$REMOTE_USER" "$ip" "rm -f /usr/local/share/ca-certificates/step-ca-root.crt 2>/dev/null; update-ca-certificates 2>/dev/null" || true
  done
  success "Step-CA root certificate removed"

  # Step 5: Reset node DNS configuration to original values
  doing "Step 5/10: Resetting DNS configuration..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    # Get original DNS from cluster-info.json (captured during initial detection)
    local original_dns1="" original_dns2="" original_search=""
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      original_dns1=$(jq -r --arg name "$node" '.nodes[] | select(.name == $name) | .dns.dns1 // ""' "$CLUSTER_INFO_FILE")
      original_dns2=$(jq -r --arg name "$node" '.nodes[] | select(.name == $name) | .dns.dns2 // ""' "$CLUSTER_INFO_FILE")
      original_search=$(jq -r --arg name "$node" '.nodes[] | select(.name == $name) | .dns.search // ""' "$CLUSTER_INFO_FILE")
    fi

    if [ -n "$original_dns1" ] && [ "$original_dns1" != "null" ]; then
      info "  Restoring original DNS on $node: DNS1=$original_dns1 DNS2=$original_dns2"
      local dns_cmd="pvesh set /nodes/$node/dns -dns1 '$original_dns1'"
      [ -n "$original_dns2" ] && [ "$original_dns2" != "null" ] && dns_cmd+=" -dns2 '$original_dns2'"
      [ -n "$original_search" ] && [ "$original_search" != "null" ] && dns_cmd+=" -search '$original_search'"
      sshRun "$REMOTE_USER" "$ip" "$dns_cmd" 2>/dev/null || warn "  Failed to restore DNS via pvesh on $node"
    else
      # Fallback: use gateway if original DNS not captured
      local fallback_dns
      fallback_dns=$(jq -r '.network.external.gateway // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)
      if [ -n "$fallback_dns" ]; then
        info "  No original DNS found for $node, using gateway: $fallback_dns"
        sshRun "$REMOTE_USER" "$ip" "pvesh set /nodes/$node/dns -dns1 '$fallback_dns'" 2>/dev/null || true
      else
        warn "  No DNS configuration found for $node - skipping"
      fi
    fi
  done
  success "DNS configuration reset"

  # Step 6: Remove hashicorp API user and role
  doing "Step 6/10: Removing hashicorp API user and role..."
  sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" "pveum user delete hashicorp@pam 2>/dev/null; pveum token delete hashicorp@pam hashicorp-token 2>/dev/null; pveum role delete HashicorpBuild 2>/dev/null" || true
  success "Hashicorp API user and role removed"

  # Step 7: Remove labnet SDN
  doing "Step 7/10: Removing labnet SDN configuration..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing iptables SNAT rules on $node..."
    # Remove SNAT/MASQUERADE rules for labnet subnet (172.16.0.0/24 default, also check cluster-info)
    local labnet_cidr="172.16.0.0/24"
    local egress_ip=""
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      labnet_cidr=$(jq -r '.network.labnet.cidr // "172.16.0.0/24"' "$CLUSTER_INFO_FILE")
      egress_ip=$(jq -r '.network.labnet.egress_ip // ""' "$CLUSTER_INFO_FILE")
    fi
    sshRun "$REMOTE_USER" "$ip" "iptables -t nat -S POSTROUTING 2>/dev/null | grep -E '(-s ${labnet_cidr}.*MASQUERADE|-s ${labnet_cidr}.*SNAT)' | while read -r rule; do iptables -t nat \$(echo \"\$rule\" | sed 's/^-A/-D/') 2>/dev/null || true; done" || true
    # Save iptables rules
    sshRun "$REMOTE_USER" "$ip" "mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4 2>/dev/null" || true

    # Remove policy-based routing configuration
    info "  Removing PBR configuration on $node..."
    sshRun "$REMOTE_USER" "$ip" "
      # Remove policy rules (both labnet subnet and egress IP)
      ip rule del from ${labnet_cidr} table services priority 99 2>/dev/null || true
      ip rule del from ${egress_ip:-0.0.0.0} table services priority 100 2>/dev/null || true
      # Flush services routing table
      ip route flush table services 2>/dev/null || true
      # Remove PBR lines from /etc/network/interfaces
      if [ -f /etc/network/interfaces ]; then
        sed -i '/# Policy-based routing for labnet egress/d' /etc/network/interfaces 2>/dev/null || true
        sed -i '/post-up ip route add.*table services/d' /etc/network/interfaces 2>/dev/null || true
        sed -i '/post-up ip rule add.*table services/d' /etc/network/interfaces 2>/dev/null || true
        sed -i '/pre-down ip rule del.*table services/d' /etc/network/interfaces 2>/dev/null || true
      fi
    " || true
  done
  # Remove SDN from cluster (only needs to run on one node)
  info "  Removing SDN zone and vnet..."
  sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" "
    rm -f /etc/pve/sdn/subnets.cfg 2>/dev/null
    touch /etc/pve/sdn/subnets.cfg
    pvesh delete /cluster/sdn/vnets/labnet 2>/dev/null || true
    pvesh delete /cluster/sdn/zones/labzone 2>/dev/null || true
    pvesh set /cluster/sdn 2>/dev/null || true
  " || true
  success "Labnet SDN removed"

  # Step 8: Clean local files
  doing "Step 8/10: Cleaning local configuration files..."
  rm -f hosts.json 2>/dev/null || true

  # Remove auto-generated sections from terraform.tfvars (keep manual config)
  if [ -f "terraform/terraform.tfvars" ]; then
    info "  Cleaning terraform.tfvars..."
    # Use a temp file approach that works on both macOS and Linux
    local tfvars_tmp
    tfvars_tmp=$(mktemp)
    # Remove auto-generated sections (pattern: comment line to next blank line)
    grep -v -E '^# (Proxmox cluster node IPs|DNS cluster nodes|Labnet DHCP Configuration|Bootstrap DNS for).*\(auto-generated' terraform/terraform.tfvars 2>/dev/null > "$tfvars_tmp" || true
    if [ -s "$tfvars_tmp" ]; then
      mv "$tfvars_tmp" terraform/terraform.tfvars
    else
      rm -f "$tfvars_tmp"
    fi
  fi

  # Remove storage and network config from cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    info "  Cleaning cluster-info.json..."
    local cluster_tmp
    cluster_tmp=$(mktemp)
    if jq 'del(.storage) | del(.network) | del(.dns_postfix) | del(.ad_config)' "$CLUSTER_INFO_FILE" > "$cluster_tmp" 2>/dev/null; then
      mv "$cluster_tmp" "$CLUSTER_INFO_FILE"
    else
      rm -f "$cluster_tmp"
      warn "  Failed to clean cluster-info.json"
    fi
  fi

  # Clean packer storage settings
  if [ -f "packer/packer.auto.pkrvars.hcl" ]; then
    info "  Cleaning packer.auto.pkrvars.hcl..."
    local packer_tmp
    packer_tmp=$(mktemp)
    if grep -v "^template_storage" packer/packer.auto.pkrvars.hcl > "$packer_tmp" 2>/dev/null; then
      mv "$packer_tmp" packer/packer.auto.pkrvars.hcl
    else
      rm -f "$packer_tmp"
    fi
  fi

  # Clean terraform state (only if docker is available)
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    info "  Cleaning terraform state..."
    local state_list
    state_list=$(docker compose run --rm -T terraform state list 2>/dev/null) || true
    if [ -n "$state_list" ]; then
      echo "$state_list" | while read -r resource; do
        docker compose run --rm -T terraform state rm "$resource" 2>/dev/null || true
      done
    fi
  else
    info "  Skipping terraform state cleanup (docker not available)"
  fi

  success "Local files cleaned"

  # Step 9: Remove Tailscale DNS override (if configured)
  doing "Step 9/10: Resetting Tailscale DNS settings..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    if sshRun "$REMOTE_USER" "$ip" "command -v tailscale" &>/dev/null; then
      info "  Re-enabling Tailscale DNS on $node..."
      sshRun "$REMOTE_USER" "$ip" "tailscale set --accept-dns=true 2>/dev/null" || true
    fi
  done
  success "Tailscale DNS settings reset"

  # Step 10: Remove SSH keys (LAST - we need SSH for all previous steps!)
  doing "Step 10/10: Removing SSH keys from nodes..."
  local ssh_removal_failed=false
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing SSH keys on $node..."

    # Use BatchMode to prevent password prompts - fail cleanly if key auth doesn't work
    local ssh_opts="-i $ENTERPRISE_KEY_PATH -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

    # Remove enterprise key (labenterpriseadmin) from Proxmox nodes
    if [ -f "${ENTERPRISE_PUBKEY_PATH}" ]; then
      local enterprise_comment
      enterprise_comment=$(awk '{print $NF}' "${ENTERPRISE_PUBKEY_PATH}")
      if [ -n "$enterprise_comment" ]; then
        if ! ssh $ssh_opts "$REMOTE_USER@$ip" "grep -v '${enterprise_comment}' /root/.ssh/authorized_keys > /tmp/ak_tmp 2>/dev/null && mv /tmp/ak_tmp /root/.ssh/authorized_keys" 2>/dev/null; then
          warn "  Failed to remove enterprise key on $node (key auth may have failed)"
          ssh_removal_failed=true
        fi
      fi
    fi

    # Also remove legacy lab-deploy key if present (for backward compatibility)
    ssh $ssh_opts "$REMOTE_USER@$ip" "grep -v 'lab-deploy' /root/.ssh/authorized_keys > /tmp/ak_tmp 2>/dev/null && mv /tmp/ak_tmp /root/.ssh/authorized_keys" 2>/dev/null || true
  done
  if [ "$ssh_removal_failed" = true ]; then
    warn "Some SSH keys could not be removed automatically. You may need to remove them manually from /root/.ssh/authorized_keys on the Proxmox nodes."
  else
    success "SSH keys removed from nodes"
  fi

  echo
  success "Complete deployment purge finished!"
  warn "You may want to delete the local crypto/ directory if you no longer need the SSH keys."
  warn "You may also want to delete cluster-info.json to start fresh."
}