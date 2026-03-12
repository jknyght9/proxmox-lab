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

    # Extract step-ca hosts from state
    local STEP_CA_HOSTS
    STEP_CA_HOSTS=$(echo "$TF_STATE" | jq -c '
      [.values.root_module.child_modules[]? |
       select(.address | startswith("module.step-ca")) |
       .resources[]? |
       select(.type == "proxmox_lxc") |
       {hostname: .values.hostname, ip: .values.network[0].ip}
      ] // []' 2>/dev/null) || STEP_CA_HOSTS="[]"

    # Extract dns-labnet hosts from state (internal)
    local LABNET_HOSTS
    LABNET_HOSTS=$(echo "$TF_STATE" | jq -c '
      [.values.root_module.child_modules[]? |
       select(.address | startswith("module.dns-labnet")) |
       .resources[]? |
       select(.type == "proxmox_lxc") |
       {hostname: .values.hostname, ip: .values.network[0].ip}
      ] // []' 2>/dev/null) || LABNET_HOSTS="[]"

    # Combine external hosts
    EXTERNAL_HOSTS=$(jq -c -n --argjson dns "$DNS_HOSTS" --argjson ca "$STEP_CA_HOSTS" '$dns + $ca')
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

function updateTerraformFromClusterInfo() {
  doing "Updating terraform.tfvars from cluster configuration..."

  local TFVARS_FILE="terraform/terraform.tfvars"
  local CREDS_FILE="$CRYPTO_DIR/proxmox-credentials.json"

  # Check if cluster-info.json exists
  if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    error "cluster-info.json not found. Run setup again."
    return 1
  fi

  # Load values from cluster-info.json
  local EXT_GW=$(jq -r '.network.external.gateway // ""' "$CLUSTER_INFO_FILE")
  local DNS_START=$(jq -r '.network.external.dns_start_ip // ""' "$CLUSTER_INFO_FILE")
  local SVC_START=$(jq -r '.network.external.services_start_ip // ""' "$CLUSTER_INFO_FILE")
  local INT_CIDR_VAL=$(jq -r '.network.labnet.cidr // ""' "$CLUSTER_INFO_FILE")
  local INT_GW=$(jq -r '.network.labnet.gateway // ""' "$CLUSTER_INFO_FILE")
  local DNS_POSTFIX_VAL=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
  local BRIDGE_VAL=$(jq -r '.network.selected_bridge // "vmbr0"' "$CLUSTER_INFO_FILE")
  local STORAGE_VAL=$(jq -r '.storage.selected // "local-lvm"' "$CLUSTER_INFO_FILE")
  local STORAGE_TYPE_VAL=$(jq -r '.storage.type // "lvm"' "$CLUSTER_INFO_FILE")

  # Load API credentials if available
  local API_URL="" API_TOKEN_ID="" API_TOKEN_SECRET=""
  if [ -f "$CREDS_FILE" ]; then
    API_URL=$(jq -r '.proxmox_api_url // ""' "$CREDS_FILE")
    API_TOKEN_ID=$(jq -r '.proxmox_api_token_id // ""' "$CREDS_FILE")
    API_TOKEN_SECRET=$(jq -r '.proxmox_api_token_secret // ""' "$CREDS_FILE")
  fi

  # Copy from example if doesn't exist
  if [ ! -f "$TFVARS_FILE" ]; then
    if [ -f "terraform/terraform.tfvars.example" ]; then
      cp terraform/terraform.tfvars.example "$TFVARS_FILE"
      info "Created terraform.tfvars from example"
    else
      error "terraform.tfvars.example not found"
      return 1
    fi
  fi

  # Helper function for cross-platform sed
  sed_inplace() {
    if sed --version >/dev/null 2>&1; then
      sed -i "$@"
    else
      sed -i '' "$@"
    fi
  }

  # Update Proxmox API credentials (if available)
  if [ -n "$API_URL" ] && [ -n "$API_TOKEN_ID" ] && [ -n "$API_TOKEN_SECRET" ] && \
     [ "$API_TOKEN_SECRET" != "RETRIEVE_FROM_PROXMOX_OR_REGENERATE" ] && \
     [ "$API_TOKEN_SECRET" != "PASTE_TOKEN_SECRET_HERE" ]; then
    sed_inplace "s|^proxmox_api_url[[:space:]]*=.*|proxmox_api_url      = \"$API_URL\"|" "$TFVARS_FILE"
    sed_inplace "s|^proxmox_api_token_id[[:space:]]*=.*|proxmox_api_token_id = \"$API_TOKEN_ID\"|" "$TFVARS_FILE"
    sed_inplace "s|^proxmox_api_token[[:space:]]*=.*|proxmox_api_token    = \"$API_TOKEN_SECRET\"|" "$TFVARS_FILE"
    info "  proxmox_api_url = \"$API_URL\""
    info "  proxmox_api_token_id = \"$API_TOKEN_ID\""
    info "  proxmox_api_token = \"<set from credentials>\""
  else
    warn "  Proxmox API credentials not available - update terraform.tfvars manually"
  fi

  # Update proxmox_target_node (primary node)
  if [ ${#CLUSTER_NODES[@]} -gt 0 ]; then
    sed_inplace "s|^proxmox_target_node[[:space:]]*=.*|proxmox_target_node  = \"${CLUSTER_NODES[0]}\"|" "$TFVARS_FILE"
    info "  proxmox_target_node = \"${CLUSTER_NODES[0]}\""
  fi

  # Update network_gateway_address
  sed_inplace "s|^network_gateway_address[[:space:]]*=.*|network_gateway_address = \"$EXT_GW\"|" "$TFVARS_FILE"
  info "  network_gateway_address = \"$EXT_GW\""

  # Update network_interface_bridge
  sed_inplace "s|^network_interface_bridge[[:space:]]*=.*|network_interface_bridge = \"$BRIDGE_VAL\"|" "$TFVARS_FILE"
  info "  network_interface_bridge = \"$BRIDGE_VAL\""

  # Update lxc_storage - LXC containers require local block storage (not NFS)
  # NFS and other file-level storage don't support container directories
  local LXC_STORAGE_VAL="local-lvm"
  if [ "$STORAGE_TYPE_VAL" = "nfs" ] || [ "$STORAGE_TYPE_VAL" = "cifs" ]; then
    info "  Note: Using local-lvm for LXC (NFS/CIFS don't support containers)"
  else
    # For non-NFS shared storage (ceph, iscsi, lvm-thin), use the selected storage
    LXC_STORAGE_VAL="$STORAGE_VAL"
  fi
  if grep -q "^lxc_storage" "$TFVARS_FILE"; then
    sed_inplace "s|^lxc_storage[[:space:]]*=.*|lxc_storage = \"$LXC_STORAGE_VAL\"|" "$TFVARS_FILE"
  else
    echo "" >> "$TFVARS_FILE"
    echo "lxc_storage = \"$LXC_STORAGE_VAL\"" >> "$TFVARS_FILE"
  fi
  info "  lxc_storage = \"$LXC_STORAGE_VAL\""

  # Update vm_storage (for VM disks - should match template storage)
  if grep -q "^vm_storage" "$TFVARS_FILE"; then
    sed_inplace "s|^vm_storage[[:space:]]*=.*|vm_storage = \"$STORAGE_VAL\"|" "$TFVARS_FILE"
  else
    echo "" >> "$TFVARS_FILE"
    echo "# VM storage (should match template storage for fast cloning)" >> "$TFVARS_FILE"
    echo "vm_storage = \"$STORAGE_VAL\"" >> "$TFVARS_FILE"
  fi
  info "  vm_storage = \"$STORAGE_VAL\""

  # Update dns_postfix
  sed_inplace "s|^dns_postfix[[:space:]]*=.*|dns_postfix = \"$DNS_POSTFIX_VAL\"|" "$TFVARS_FILE"
  info "  dns_postfix = \"$DNS_POSTFIX_VAL\""

  # Update dns_primary_ipv4
  sed_inplace "s|^dns_primary_ipv4[[:space:]]*=.*|dns_primary_ipv4 = \"$DNS_START\"|" "$TFVARS_FILE"
  info "  dns_primary_ipv4 = \"$DNS_START\""

  # Update bootstrap_dns (use gateway for initial provisioning before internal DNS is ready)
  # This is critical for networks that block external DNS (1.1.1.1, 8.8.8.8, etc.)
  if grep -q "^bootstrap_dns" "$TFVARS_FILE"; then
    sed_inplace "s|^bootstrap_dns[[:space:]]*=.*|bootstrap_dns = \"$EXT_GW\"|" "$TFVARS_FILE"
  else
    echo "" >> "$TFVARS_FILE"
    echo "# Bootstrap DNS for initial provisioning (auto-generated from gateway)" >> "$TFVARS_FILE"
    echo "bootstrap_dns = \"$EXT_GW\"" >> "$TFVARS_FILE"
  fi
  info "  bootstrap_dns = \"$EXT_GW\""

  # Update step-ca_eth0_ipv4_cidr (service start IP with /24)
  local EXT_CIDR_VAL=$(jq -r '.network.external.cidr // ""' "$CLUSTER_INFO_FILE")
  local CIDR_MASK=$(echo "$EXT_CIDR_VAL" | grep -oE '/[0-9]+$')
  sed_inplace "s|^step-ca_eth0_ipv4_cidr[[:space:]]*=.*|step-ca_eth0_ipv4_cidr = \"${SVC_START}${CIDR_MASK}\"|" "$TFVARS_FILE"
  info "  step-ca_eth0_ipv4_cidr = \"${SVC_START}${CIDR_MASK}\""

  # Build and update proxmox_node_ips map
  local NODE_IPS_MAP="{\n"
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    [ $i -gt 0 ] && NODE_IPS_MAP+=",\n"
    NODE_IPS_MAP+="  $node = \"$ip\""
  done
  NODE_IPS_MAP+="\n}"

  # Remove existing proxmox_node_ips block and add new
  sed_inplace '/^proxmox_node_ips/,/^}/d' "$TFVARS_FILE"
  echo "" >> "$TFVARS_FILE"
  echo "# Proxmox cluster node IPs (auto-generated by setup.sh)" >> "$TFVARS_FILE"
  echo -e "proxmox_node_ips = $NODE_IPS_MAP" >> "$TFVARS_FILE"
  info "  proxmox_node_ips updated"

  # Build DNS main nodes configuration
  local DNS_MAIN_CONFIG="["
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local hostname="dns-$(printf '%02d' $((i + 1)))"
    # Calculate IP from DNS_START
    local base_ip=$(echo "$DNS_START" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.')
    local start_octet=$(echo "$DNS_START" | grep -oE '[0-9]+$')
    local ip="${base_ip}$((start_octet + i))${CIDR_MASK}"
    [ $i -gt 0 ] && DNS_MAIN_CONFIG+=", "
    DNS_MAIN_CONFIG+="\n  { hostname = \"$hostname\", target_node = \"$node\", ip = \"$ip\", gw = \"$EXT_GW\" }"
  done
  DNS_MAIN_CONFIG+="\n]"

  # Remove and rewrite dns_main_nodes
  sed_inplace '/^dns_main_nodes/,/^\]/d' "$TFVARS_FILE"
  echo "" >> "$TFVARS_FILE"
  echo "# DNS cluster nodes - Main cluster (auto-generated)" >> "$TFVARS_FILE"
  echo -e "dns_main_nodes = $DNS_MAIN_CONFIG" >> "$TFVARS_FILE"
  info "  dns_main_nodes updated"

  # Build DNS labnet nodes configuration (max 2)
  if jq -e '.network.labnet.enabled == true' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    local LABNET_DNS_CONFIG="["
    local labnet_count=$((${#CLUSTER_NODES[@]} < 2 ? ${#CLUSTER_NODES[@]} : 2))
    local labnet_base=$(echo "$INT_GW" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.')
    local labnet_mask=$(echo "$INT_CIDR_VAL" | grep -oE '/[0-9]+$')

    for i in $(seq 0 $((labnet_count - 1))); do
      local node="${CLUSTER_NODES[$i]}"
      local hostname="labnet-dns-$(printf '%02d' $((i + 1)))"
      local ip="${labnet_base}$((3 + i))${labnet_mask}"
      [ $i -gt 0 ] && LABNET_DNS_CONFIG+=", "
      LABNET_DNS_CONFIG+="\n  { hostname = \"$hostname\", target_node = \"$node\", ip = \"$ip\", gw = \"$INT_GW\" }"
    done
    LABNET_DNS_CONFIG+="\n]"

    # Remove and rewrite dns_labnet_nodes
    sed_inplace '/^dns_labnet_nodes/,/^\]/d' "$TFVARS_FILE"
    echo "" >> "$TFVARS_FILE"
    echo "# DNS cluster nodes - Labnet SDN cluster (auto-generated)" >> "$TFVARS_FILE"
    echo -e "dns_labnet_nodes = $LABNET_DNS_CONFIG" >> "$TFVARS_FILE"
    info "  dns_labnet_nodes updated"

    # Configure labnet DHCP settings (auto-generated from labnet CIDR)
    # DHCP range: .100 to .200, router is the gateway
    local dhcp_start="${labnet_base}100"
    local dhcp_end="${labnet_base}200"

    # Update or add DHCP settings
    if grep -q "^labnet_dhcp_enabled" "$TFVARS_FILE"; then
      sed_inplace "s|^labnet_dhcp_enabled[[:space:]]*=.*|labnet_dhcp_enabled    = true|" "$TFVARS_FILE"
      sed_inplace "s|^labnet_dhcp_start[[:space:]]*=.*|labnet_dhcp_start      = \"$dhcp_start\"|" "$TFVARS_FILE"
      sed_inplace "s|^labnet_dhcp_end[[:space:]]*=.*|labnet_dhcp_end        = \"$dhcp_end\"|" "$TFVARS_FILE"
      sed_inplace "s|^labnet_dhcp_router[[:space:]]*=.*|labnet_dhcp_router     = \"$INT_GW\"|" "$TFVARS_FILE"
    else
      echo "" >> "$TFVARS_FILE"
      echo "# Labnet DHCP Configuration (auto-generated)" >> "$TFVARS_FILE"
      echo "labnet_dhcp_enabled    = true" >> "$TFVARS_FILE"
      echo "labnet_dhcp_start      = \"$dhcp_start\"" >> "$TFVARS_FILE"
      echo "labnet_dhcp_end        = \"$dhcp_end\"" >> "$TFVARS_FILE"
      echo "labnet_dhcp_router     = \"$INT_GW\"" >> "$TFVARS_FILE"
      echo "labnet_dhcp_lease_time = \"86400\"" >> "$TFVARS_FILE"
    fi
    info "  labnet_dhcp settings updated (range: $dhcp_start - $dhcp_end, router: $INT_GW)"
  fi

  # Load and apply service passwords from crypto/service-passwords.json
  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"
  if [ -f "$PASSWORDS_FILE" ]; then
    local PIHOLE_ADMIN=$(jq -r '.pihole_admin_password' "$PASSWORDS_FILE")
    local PIHOLE_ROOT=$(jq -r '.pihole_root_password' "$PASSWORDS_FILE")
    local STEPCA_ROOT=$(jq -r '.["step-ca_root_password"]' "$PASSWORDS_FILE")
    local KASM_ADMIN=$(jq -r '.kasm_admin_password' "$PASSWORDS_FILE")

    sed_inplace "s|^pihole_admin_password[[:space:]]*=.*|pihole_admin_password = \"$PIHOLE_ADMIN\"|" "$TFVARS_FILE"
    sed_inplace "s|^pihole_root_password[[:space:]]*=.*|pihole_root_password  = \"$PIHOLE_ROOT\"|" "$TFVARS_FILE"
    sed_inplace "s|^step-ca_root_password[[:space:]]*=.*|step-ca_root_password  = \"$STEPCA_ROOT\"|" "$TFVARS_FILE"
    sed_inplace "s|^kasm_admin_password[[:space:]]*=.*|kasm_admin_password = \"$KASM_ADMIN\"|" "$TFVARS_FILE"

    info "  Service passwords populated from $PASSWORDS_FILE"
  else
    warn "  Service passwords file not found - passwords not auto-populated"
  fi

  success "Terraform configuration updated from cluster-info.json"
}