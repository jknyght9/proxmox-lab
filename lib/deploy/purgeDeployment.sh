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
  doing "Step 3/10: Removing ACME certificates..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing ACME config on $node..."
    sshRun "$REMOTE_USER" "$ip" "pvenode config set --delete acme 2>/dev/null; pvenode acme account deactivate 2>/dev/null" || true
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

  # Step 5: Reset node DNS configuration
  doing "Step 5/10: Resetting DNS configuration..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Resetting DNS on $node..."
    sshRun "$REMOTE_USER" "$ip" "sed -i 's/^nameserver .*/nameserver 1.1.1.1/' /etc/resolv.conf 2>/dev/null" || true
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
    sed -i.bak '/# Proxmox cluster node IPs (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    sed -i.bak '/# DNS cluster nodes - Main cluster (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    sed -i.bak '/# DNS cluster nodes - Labnet SDN cluster (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    sed -i.bak '/# Labnet DHCP Configuration (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    sed -i.bak '/# Bootstrap DNS for initial provisioning (auto-generated/,/^$/d' terraform/terraform.tfvars 2>/dev/null || true
    rm -f terraform/terraform.tfvars.bak 2>/dev/null || true
  fi
  # Remove storage and network config from cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local tmp=$(mktemp)
    jq 'del(.storage) | del(.network) | del(.dns_postfix) | del(.ad_config)' "$CLUSTER_INFO_FILE" > "$tmp" && mv "$tmp" "$CLUSTER_INFO_FILE"
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
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  Removing SSH keys on $node..."

    # Remove enterprise key (labenterpriseadmin) from Proxmox nodes
    if [ -f "${ENTERPRISE_PUBKEY_PATH}" ]; then
      local enterprise_comment
      enterprise_comment=$(awk '{print $NF}' "${ENTERPRISE_PUBKEY_PATH}")
      if [ -n "$enterprise_comment" ]; then
        sshRun "$REMOTE_USER" "$ip" "grep -v '${enterprise_comment}' /root/.ssh/authorized_keys > /tmp/ak_tmp 2>/dev/null && mv /tmp/ak_tmp /root/.ssh/authorized_keys || true" || true
      fi
    fi

    # Also remove legacy lab-deploy key if present (for backward compatibility)
    sshRun "$REMOTE_USER" "$ip" "grep -v 'lab-deploy' /root/.ssh/authorized_keys > /tmp/ak_tmp 2>/dev/null && mv /tmp/ak_tmp /root/.ssh/authorized_keys || true" || true
  done
  success "SSH keys removed from nodes"

  echo
  success "Complete deployment purge finished!"
  warn "You may want to delete the local crypto/ directory if you no longer need the SSH keys."
  warn "You may also want to delete cluster-info.json to start fresh."
}