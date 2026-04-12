#!/usr/bin/env bash

function generateHostsJsonFromModules() {
  # Generate hosts.json by querying individual module outputs
  # This is used when the combined host-records output fails (e.g., during targeted apply)
  doing "Generating hosts.json from individual module outputs..."

  local EXTERNAL_HOSTS="[]"
  local INTERNAL_HOSTS="[]"

  # Query terraform state directly using terraform show
  local TF_STATE
  TF_STATE=$(docker compose run --rm -T terraform show -json 2>/dev/null) || true

  if [ -n "$TF_STATE" ] && [ "$TF_STATE" != "null" ]; then
    # Extract dns-main hosts from state (proxmox_lxc resource)
    local DNS_HOSTS
    DNS_HOSTS=$(echo "$TF_STATE" | jq -c '
      [.values.root_module.child_modules[]? |
       select(.address | startswith("module.dns-main")) |
       .resources[]? |
       select(.type == "proxmox_lxc") |
       {hostname: .values.hostname, ip: .values.network[0].ip}
      ] // []' 2>/dev/null) || DNS_HOSTS="[]"

    # Note: step-ca has been replaced by Vault PKI - no LXC container to track

    # Extract dns-labnet hosts from state (internal)
    local LABNET_HOSTS
    LABNET_HOSTS=$(echo "$TF_STATE" | jq -c '
      [.values.root_module.child_modules[]? |
       select(.address | startswith("module.dns-labnet")) |
       .resources[]? |
       select(.type == "proxmox_lxc") |
       {hostname: .values.hostname, ip: .values.network[0].ip}
      ] // []' 2>/dev/null) || LABNET_HOSTS="[]"

    # Combine external hosts (step-ca removed - CA is now Vault PKI)
    EXTERNAL_HOSTS="$DNS_HOSTS"
    INTERNAL_HOSTS="$LABNET_HOSTS"
  fi

  # Create the hosts.json structure
  jq -n --argjson ext "$EXTERNAL_HOSTS" --argjson int "$INTERNAL_HOSTS" \
    '{external: $ext, internal: $int}' > hosts.json

  if jq -e '.external | length > 0' hosts.json >/dev/null 2>&1; then
    success "Generated hosts.json from module state"
    return 0
  else
    warn "No hosts found in terraform state"
    return 1
  fi
}

function generateHostsJson() {
  doing "Generating hosts.json from Terraform output..."

  if [ ! -d "terraform" ]; then
    warn "terraform directory not found"
    return 1
  fi

  # Try to get hosts from Terraform output
  local TF_OUTPUT
  TF_OUTPUT=$(docker compose run --rm -T terraform output -json host-records 2>/dev/null) || true

  if [ -n "$TF_OUTPUT" ] && [ "$TF_OUTPUT" != "null" ] && jq -e '.external' <<<"$TF_OUTPUT" >/dev/null 2>&1; then
    echo "$TF_OUTPUT" > hosts.json
    success "Generated hosts.json from Terraform output"
    return 0
  fi

  # Fallback to individual module outputs
  generateHostsJsonFromModules
}

# Refreshes hosts.json with actual VM IPs from Proxmox QEMU guest agent
# This resolves DHCP IP mismatches after VM deployment
function refreshHostsJsonFromProxmox() {
  local vm_prefix="${1:-nomad}"
  local vmid_start="${2:-905}"
  local vmid_end="${3:-907}"
  local max_wait="${4:-120}"  # Max seconds to wait for guest agent

  doing "Refreshing hosts.json with actual VM IPs from Proxmox..."

  # Query each Proxmox node for VM IPs
  local updated_hosts=()
  for vmid in $(seq $vmid_start $vmid_end); do
    local vm_name=""
    local vm_ip=""
    local found_node_ip=""

    # Try each node to find the VM
    for node_ip in "${CLUSTER_NODE_IPS[@]}"; do
      # Check if VM exists on this node
      local vm_config
      vm_config=$(sshRun "$REMOTE_USER" "$node_ip" "qm config $vmid 2>/dev/null" || echo "")

      if [ -n "$vm_config" ]; then
        vm_name=$(echo "$vm_config" | grep "^name:" | awk '{print $2}')
        found_node_ip="$node_ip"
        break
      fi
    done

    # If VM found, wait for guest agent to be ready
    if [ -n "$vm_name" ] && [ -n "$found_node_ip" ]; then
      info "Waiting for QEMU guest agent on $vm_name ($vmid)..."
      local elapsed=0
      local interval=5

      while [ $elapsed -lt $max_wait ]; do
        vm_ip=$(sshRun "$REMOTE_USER" "$found_node_ip" "qm guest cmd $vmid network-get-interfaces 2>/dev/null | jq -r '.[].\"ip-addresses\"[]? | select(.\"ip-address-type\"==\"ipv4\" and (.\"ip-address\" | startswith(\"10.\"))) | .\"ip-address\"' 2>/dev/null | head -1" || echo "")

        if [ -n "$vm_ip" ]; then
          success "Found $vm_name ($vmid): $vm_ip"
          updated_hosts+=("{\"hostname\":\"$vm_name\",\"ip\":\"$vm_ip\"}")
          break
        fi

        printf "  Waiting for guest agent... (%ds/%ds)\r" "$elapsed" "$max_wait"
        sleep $interval
        elapsed=$((elapsed + interval))
      done

      if [ -z "$vm_ip" ]; then
        warn "Timeout waiting for guest agent on $vm_name ($vmid)"
      fi
    fi
  done

  # Update hosts.json with the new IPs
  if [ ${#updated_hosts[@]} -gt 0 ]; then
    # Read existing hosts.json
    local existing_external
    existing_external=$(jq -c '[.external[] | select(.hostname | startswith("'$vm_prefix'") | not)]' hosts.json 2>/dev/null || echo "[]")

    local existing_internal
    existing_internal=$(jq -c '.internal // []' hosts.json 2>/dev/null || echo "[]")

    # Combine existing non-VM hosts with new VM hosts
    local new_hosts_json
    new_hosts_json=$(printf '%s\n' "${updated_hosts[@]}" | jq -s '.')

    # Merge and write back
    jq -n --argjson existing "$existing_external" \
          --argjson new "$new_hosts_json" \
          --argjson internal "$existing_internal" \
          '{external: ($existing + $new), internal: $internal}' > hosts.json

    success "hosts.json updated with actual VM IPs"
    jq -r '.external[] | select(.hostname | startswith("'$vm_prefix'")) | "  - \(.hostname): \(.ip)"' hosts.json
  else
    warn "No VM IPs found via guest agent. hosts.json not updated."
    return 1
  fi
}
