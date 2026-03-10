#!/usr/bin/env bash

# disableTailscaleDNS - Disable Tailscale DNS management on all cluster nodes
#
# Configures Tailscale to not overwrite /etc/resolv.conf, allowing the system
# to use manually configured DNS (Pi-hole). Tailscale networking remains functional.
#
# Note: MagicDNS names (e.g., node.tailnet.ts.net) won't resolve on these nodes
# after disabling. Use Tailscale IPs or add local DNS records if needed.
#
# Globals read: REMOTE_USER, CLUSTER_NODES, CLUSTER_NODE_IPS
# Arguments: None
# Returns: 0 always (skips nodes without Tailscale)
function disableTailscaleDNS() {
  doing "Checking for Tailscale on cluster nodes..."

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    if sshRun "$REMOTE_USER" "$ip" "command -v tailscale" &>/dev/null; then
      info "  Disabling Tailscale DNS management on $node..."
      if sshRun "$REMOTE_USER" "$ip" "tailscale set --accept-dns=false" 2>/dev/null; then
        success "  $node: Tailscale DNS disabled"
      else
        warn "  $node: Failed to disable Tailscale DNS (may require elevated permissions)"
      fi
    else
      info "  $node: Tailscale not installed, skipping"
    fi
  done
}
