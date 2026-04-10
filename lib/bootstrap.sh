#!/usr/bin/env bash

# bootstrap.sh - Bootstrap configuration and cluster discovery
#
# Reads bootstrap.yml for minimal input (Proxmox IP, password, network,
# DNS suffix), auto-discovers cluster topology, storage pools, and network
# bridges, then generates Terraform and Packer configuration files.
#
# Replaces the old flow of:
#   cluster-info.json → updateTerraformFromClusterInfo (25+ sed ops)
#   cluster-info.json → updatePackerFromClusterInfo (12+ sed ops)
#
# Dependencies: jq, sshpass (for initial password-based SSH)

# These are set lazily (not at source time) because CRYPTO_DIR and
# SCRIPT_DIR may not be defined yet when this file is sourced.
_bootstrap_init_vars() {
  BOOTSTRAP_FILE="${SCRIPT_DIR}/bootstrap.yml"
  CLUSTER_INFO_FILE="${SCRIPT_DIR}/cluster-info.json"
  CREDENTIALS_FILE="${CRYPTO_DIR}/proxmox-credentials.json"
}

# =============================================================================
# YAML Parsing (uses python3 for reliable handling of special characters)
# =============================================================================

# Read a value from bootstrap.yml by dot-separated key path.
# Uses python3 (available on macOS and Linux) to avoid sed/xargs issues
# with special characters in passwords.
# Arguments: $1 = dot-separated key path (e.g., "proxmox.ip")
# Returns: value string, or empty if not found
function yamlGet() {
  local key="$1"
  local file="${2:-$BOOTSTRAP_FILE}"

  python3 -c "
import sys, re

def parse_simple_yaml(path):
    \"\"\"Minimal YAML parser for flat/one-level-nested config.\"\"\"
    result = {}
    current_section = None
    with open(path) as f:
        for line in f:
            stripped = line.rstrip()
            # Skip comments and empty lines
            if not stripped or stripped.lstrip().startswith('#'):
                continue
            # Check indentation
            indent = len(line) - len(line.lstrip())
            # Remove inline comments (but not inside quoted values)
            if '#' in stripped:
                # Only strip comments that aren't inside quotes
                in_quote = False
                quote_char = None
                for i, c in enumerate(stripped):
                    if c in ('\"', \"'\") and not in_quote:
                        in_quote = True
                        quote_char = c
                    elif c == quote_char and in_quote:
                        in_quote = False
                    elif c == '#' and not in_quote:
                        stripped = stripped[:i].rstrip()
                        break
            if indent == 0 and ':' in stripped:
                k, _, v = stripped.partition(':')
                k = k.strip()
                v = v.strip().strip('\"').strip(\"'\")
                if v:
                    result[k] = v
                else:
                    current_section = k
                    if k not in result:
                        result[k] = {}
            elif indent > 0 and current_section and ':' in stripped:
                k, _, v = stripped.partition(':')
                k = k.strip()
                v = v.strip().strip('\"').strip(\"'\")
                if isinstance(result.get(current_section), dict):
                    result[current_section][k] = v

    return result

data = parse_simple_yaml('$file')
keys = '$key'.split('.')
val = data
for k in keys:
    if isinstance(val, dict):
        val = val.get(k, '')
    else:
        val = ''
        break
print(val if val and not isinstance(val, dict) else '')
" 2>/dev/null
}

# =============================================================================
# Bootstrap Configuration
# =============================================================================

# Read and validate bootstrap.yml
# Globals set: PROXMOX_IP, PROXMOX_PASS, NETWORK_CIDR, NETWORK_GATEWAY,
#              NETWORK_BRIDGE, DNS_POSTFIX, STORAGE_TEMPLATES_OVERRIDE,
#              STORAGE_RUNTIME_OVERRIDE
function readBootstrapConfig() {
  if [ ! -f "$BOOTSTRAP_FILE" ]; then
    error "bootstrap.yml not found. Copy bootstrap.yml.example to bootstrap.yml and fill in your values."
    return 1
  fi

  doing "Reading bootstrap configuration..."

  PROXMOX_IP=$(yamlGet "proxmox.ip")
  PROXMOX_PASS=$(yamlGet "proxmox.password")
  NETWORK_CIDR=$(yamlGet "network.cidr")
  NETWORK_GATEWAY=$(yamlGet "network.gateway")
  NETWORK_BRIDGE=$(yamlGet "network.bridge")
  DNS_POSTFIX=$(yamlGet "dns_suffix")
  STORAGE_TEMPLATES_OVERRIDE=$(yamlGet "storage.templates")
  STORAGE_RUNTIME_OVERRIDE=$(yamlGet "storage.runtime")

  # Validate required fields
  local missing=()
  [ -z "$PROXMOX_IP" ] && missing+=("proxmox.ip")
  [ -z "$PROXMOX_PASS" ] && missing+=("proxmox.password")
  [ -z "$NETWORK_CIDR" ] && missing+=("network.cidr")
  [ -z "$NETWORK_GATEWAY" ] && missing+=("network.gateway")
  [ -z "$DNS_POSTFIX" ] && missing+=("dns_suffix")

  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing required fields in bootstrap.yml: ${missing[*]}"
    return 1
  fi

  info "  Proxmox IP:    $PROXMOX_IP"
  info "  Network:       $NETWORK_CIDR (gw: $NETWORK_GATEWAY)"
  info "  Bridge:        ${NETWORK_BRIDGE:-<auto-detect>}"
  info "  DNS Suffix:    $DNS_POSTFIX"
  info "  Storage:       ${STORAGE_TEMPLATES_OVERRIDE:-<auto-detect>}"

  success "Bootstrap configuration loaded"
}

# =============================================================================
# Cluster Discovery
# =============================================================================

# Discover Proxmox cluster topology by SSH-ing to the bootstrap node.
# Detects single-node vs multi-node cluster, enumerates all nodes + IPs.
#
# Globals set: IS_CLUSTER, CLUSTER_NODES[], CLUSTER_NODE_IPS[], PRIMARY_NODE
# Writes: cluster-info.json (partial — nodes + cluster status)
function discoverCluster() {
  doing "Discovering Proxmox cluster topology..."

  # SSH to the bootstrap node using password auth (first-time only)
  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

  # Check if we can reach the node
  if ! sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$PROXMOX_IP" "true" 2>/dev/null; then
    error "Cannot SSH to $PROXMOX_IP with provided password"
    return 1
  fi

  # Detect cluster membership
  local MEMBERS_JSON
  MEMBERS_JSON=$(sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$PROXMOX_IP" \
    "cat /etc/pve/.members 2>/dev/null || echo '{}'" 2>/dev/null)

  IS_CLUSTER=false
  CLUSTER_NODES=()
  CLUSTER_NODE_IPS=()

  local NODE_COUNT
  NODE_COUNT=$(echo "$MEMBERS_JSON" | jq -r '.nodelist | length // 0' 2>/dev/null || echo "0")

  if [ "$NODE_COUNT" -gt 1 ]; then
    IS_CLUSTER=true
    info "  Detected multi-node cluster ($NODE_COUNT nodes)"

    while IFS=$'\t' read -r name ip; do
      [ -z "$name" ] || [ -z "$ip" ] && continue
      CLUSTER_NODES+=("$name")
      CLUSTER_NODE_IPS+=("$ip")
      info "    $name: $ip"
    done < <(echo "$MEMBERS_JSON" | jq -r '.nodelist | to_entries[] | "\(.key)\t\(.value.ip)"' 2>/dev/null)
  else
    IS_CLUSTER=false
    # Single node — get hostname
    local HOSTNAME
    HOSTNAME=$(sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$PROXMOX_IP" "hostname" 2>/dev/null)
    CLUSTER_NODES=("${HOSTNAME:-pve}")
    CLUSTER_NODE_IPS=("$PROXMOX_IP")
    info "  Detected single-node setup: ${CLUSTER_NODES[0]} ($PROXMOX_IP)"
  fi

  PRIMARY_NODE="${CLUSTER_NODES[0]}"

  # Write cluster discovery to cluster-info.json
  local NODES_JSON="[]"
  for i in "${!CLUSTER_NODES[@]}"; do
    NODES_JSON=$(echo "$NODES_JSON" | jq --arg name "${CLUSTER_NODES[$i]}" --arg ip "${CLUSTER_NODE_IPS[$i]}" \
      '. += [{"name": $name, "ip": $ip}]')
  done

  jq -n \
    --arg detected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson is_cluster "$IS_CLUSTER" \
    --argjson nodes "$NODES_JSON" \
    --arg primary "$PRIMARY_NODE" \
    --arg dns_postfix "$DNS_POSTFIX" \
    --arg cidr "$NETWORK_CIDR" \
    --arg gateway "$NETWORK_GATEWAY" \
    '{
      detected_at: $detected_at,
      is_cluster: $is_cluster,
      nodes: $nodes,
      primary_node: $primary,
      dns_postfix: $dns_postfix,
      network: {
        external: {
          cidr: $cidr,
          gateway: $gateway
        }
      }
    }' > "$CLUSTER_INFO_FILE"

  success "Cluster discovery complete ($NODE_COUNT nodes)"
}

# =============================================================================
# Storage Discovery
# =============================================================================

# Discover available storage pools from Proxmox API and select the best
# option for templates and runtime. Clusters prefer shared storage;
# standalone uses local-lvm. LXC containers always use local-lvm
# (file-level storage like NFS/CIFS doesn't support LXC).
#
# Globals set: TEMPLATE_STORAGE, TEMPLATE_STORAGE_TYPE, RUNTIME_STORAGE,
#              LXC_STORAGE
function discoverStorage() {
  doing "Discovering storage pools..."

  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

  # Query available storage that can hold VM images
  local STORAGE_JSON
  STORAGE_JSON=$(sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$PROXMOX_IP" \
    "pvesh get /storage --output-format json" 2>/dev/null)

  if [ -z "$STORAGE_JSON" ]; then
    warn "Could not query storage — using defaults"
    TEMPLATE_STORAGE="local-lvm"
    TEMPLATE_STORAGE_TYPE="lvm"
    RUNTIME_STORAGE="local-lvm"
    LXC_STORAGE="local-lvm"
    return 0
  fi

  # Filter storage pools that can hold VM images
  local IMAGE_STORAGE
  IMAGE_STORAGE=$(echo "$STORAGE_JSON" | jq '[.[] | select(.content | contains("images"))]')

  info "  Available storage pools:"
  echo "$IMAGE_STORAGE" | jq -r '.[] | "    \(.storage) (\(.type)) \(if .shared == 1 then "[shared]" else "[local]" end)"'

  # Apply user overrides if specified
  if [ -n "$STORAGE_TEMPLATES_OVERRIDE" ]; then
    TEMPLATE_STORAGE="$STORAGE_TEMPLATES_OVERRIDE"
    TEMPLATE_STORAGE_TYPE=$(echo "$IMAGE_STORAGE" | jq -r --arg s "$TEMPLATE_STORAGE" '.[] | select(.storage == $s) | .type // "lvm"')
    info "  Templates: $TEMPLATE_STORAGE (override)"
  elif [ "$IS_CLUSTER" = "true" ]; then
    # Cluster: prefer shared storage
    local SHARED
    SHARED=$(echo "$IMAGE_STORAGE" | jq -r '[.[] | select(.shared == 1)] | first // empty')
    if [ -n "$SHARED" ] && [ "$SHARED" != "null" ]; then
      TEMPLATE_STORAGE=$(echo "$SHARED" | jq -r '.storage')
      TEMPLATE_STORAGE_TYPE=$(echo "$SHARED" | jq -r '.type')
      info "  Templates: $TEMPLATE_STORAGE (shared, auto-selected)"
    else
      TEMPLATE_STORAGE="local-lvm"
      TEMPLATE_STORAGE_TYPE="lvm"
      warn "  No shared storage found — using local-lvm for templates"
    fi
  else
    # Standalone: use local-lvm
    TEMPLATE_STORAGE="local-lvm"
    TEMPLATE_STORAGE_TYPE="lvm"
    info "  Templates: $TEMPLATE_STORAGE (standalone default)"
  fi

  if [ -n "$STORAGE_RUNTIME_OVERRIDE" ]; then
    RUNTIME_STORAGE="$STORAGE_RUNTIME_OVERRIDE"
    info "  Runtime: $RUNTIME_STORAGE (override)"
  else
    RUNTIME_STORAGE="$TEMPLATE_STORAGE"
    info "  Runtime VMs: $RUNTIME_STORAGE (same as templates)"
  fi

  # LXC containers: always local-lvm (file-level storage doesn't support LXC)
  local STORAGE_TYPE_CHECK
  STORAGE_TYPE_CHECK=$(echo "$IMAGE_STORAGE" | jq -r --arg s "$RUNTIME_STORAGE" '.[] | select(.storage == $s) | .type // "lvm"')
  if [[ "$STORAGE_TYPE_CHECK" =~ ^(nfs|cifs|glusterfs)$ ]]; then
    LXC_STORAGE="local-lvm"
    info "  Runtime LXC: local-lvm (forced — $RUNTIME_STORAGE is file-level)"
  else
    LXC_STORAGE="$RUNTIME_STORAGE"
    info "  Runtime LXC: $LXC_STORAGE"
  fi

  # Save storage config to cluster-info.json
  local tmp; tmp=$(mktemp)
  jq --arg ts "$TEMPLATE_STORAGE" --arg tt "$TEMPLATE_STORAGE_TYPE" \
    --arg rs "$RUNTIME_STORAGE" --arg ls "$LXC_STORAGE" \
    --argjson shared "$([ "$IS_CLUSTER" = "true" ] && echo "true" || echo "false")" \
    '.storage = {
      templates: $ts,
      templates_type: $tt,
      runtime: $rs,
      lxc: $ls,
      is_shared: $shared
    }' "$CLUSTER_INFO_FILE" > "$tmp" && mv "$tmp" "$CLUSTER_INFO_FILE"

  success "Storage discovery complete"
}

# =============================================================================
# Network Bridge Discovery
# =============================================================================

# Discover available network bridges and validate the configured one.
# If no bridge is specified in bootstrap.yml, auto-detect the bridge
# with the default route.
#
# Globals set: NETWORK_BRIDGE (updated if auto-detected)
function discoverNetworkBridges() {
  doing "Discovering network bridges..."

  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

  # Get available bridges
  local BRIDGES
  BRIDGES=$(sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$PROXMOX_IP" \
    "pvesh get /nodes/\$(hostname)/network --output-format json 2>/dev/null | jq -r '[.[] | select(.type == \"bridge\")] | .[].iface'" 2>/dev/null)

  if [ -z "$BRIDGES" ]; then
    warn "Could not query network bridges — using ${NETWORK_BRIDGE:-vmbr0}"
    NETWORK_BRIDGE="${NETWORK_BRIDGE:-vmbr0}"
    return 0
  fi

  info "  Available bridges: $(echo $BRIDGES | tr '\n' ' ')"

  if [ -n "$NETWORK_BRIDGE" ]; then
    # Validate user-specified bridge exists
    if echo "$BRIDGES" | grep -q "^${NETWORK_BRIDGE}$"; then
      info "  Using configured bridge: $NETWORK_BRIDGE"
    else
      warn "  Configured bridge '$NETWORK_BRIDGE' not found — auto-detecting"
      NETWORK_BRIDGE=""
    fi
  fi

  if [ -z "$NETWORK_BRIDGE" ]; then
    # Auto-detect: use the bridge with the default route
    NETWORK_BRIDGE=$(sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$PROXMOX_IP" \
      "ip route show default | head -1 | awk '{print \$5}'" 2>/dev/null)

    # The default route device might be a bridge member, not the bridge itself
    # Check if it's in our bridge list
    if ! echo "$BRIDGES" | grep -q "^${NETWORK_BRIDGE}$"; then
      # Fall back to first available bridge
      NETWORK_BRIDGE=$(echo "$BRIDGES" | head -1)
    fi

    info "  Auto-detected bridge: $NETWORK_BRIDGE"
  fi

  # Save to cluster-info.json
  local tmp; tmp=$(mktemp)
  jq --arg bridge "$NETWORK_BRIDGE" '.network.selected_bridge = $bridge' "$CLUSTER_INFO_FILE" > "$tmp" && mv "$tmp" "$CLUSTER_INFO_FILE"

  success "Network bridge: $NETWORK_BRIDGE"
}

# =============================================================================
# API Token Creation
# =============================================================================

# Create the hashicorp@pam API user and token on Proxmox.
# This replaces the createHashicorpUser() function from proxmox/setup.sh.
#
# Globals read: PROXMOX_IP, PROXMOX_PASS, CLUSTER_NODE_IPS[]
# Writes: crypto/proxmox-credentials.json
function createAPIToken() {
  doing "Creating Proxmox API token..."

  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

  # Check if token already exists and is valid
  if [ -f "$CREDENTIALS_FILE" ]; then
    local EXISTING_SECRET
    EXISTING_SECRET=$(jq -r '.proxmox_api_token_secret // ""' "$CREDENTIALS_FILE")
    if [ -n "$EXISTING_SECRET" ] && [ "$EXISTING_SECRET" != "null" ] && [ "$EXISTING_SECRET" != "RETRIEVE_FROM_PROXMOX_OR_REGENERATE" ]; then
      info "  API credentials already exist at $CREDENTIALS_FILE"
      success "API token ready"
      return 0
    fi
  fi

  # Run on the primary node via SSH
  local TOKEN_OUTPUT
  TOKEN_OUTPUT=$(sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$PROXMOX_IP" bash <<'REMOTE_SCRIPT'
    set -e

    USER="hashicorp@pam"
    ROLE="HashicorpBuild"
    TOKEN_NAME="hashicorp-token"

    # Clean up existing user/role if present
    pveum user delete "$USER" 2>/dev/null || true
    pveum role remove "$ROLE" 2>/dev/null || true

    # Create role with required privileges
    pveum roleadd "$ROLE" -privs "Sys.Audit,Sys.Console,Sys.Modify,Sys.PowerMgmt,SDN.Use,Pool.Allocate,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.Monitor,VM.PowerMgmt,VM.Snapshot"

    # Create user
    pveum user add "$USER" --enable 1

    # Grant role
    pveum aclmod / -user "$USER" -role "$ROLE"

    # Create API token (no privilege separation)
    TOKEN_JSON=$(pveum user token add "$USER" "$TOKEN_NAME" --privsep=0 --output-format json)
    TOKEN_SECRET=$(echo "$TOKEN_JSON" | jq -r '.value')

    echo "PROXMOX_TOKEN_INFO:${USER}!${TOKEN_NAME}:${TOKEN_SECRET}"
REMOTE_SCRIPT
  ) 2>/dev/null

  # Parse token from output
  local TOKEN_LINE
  TOKEN_LINE=$(echo "$TOKEN_OUTPUT" | grep "^PROXMOX_TOKEN_INFO:" | tail -1)

  if [ -z "$TOKEN_LINE" ]; then
    error "Failed to create API token"
    echo "$TOKEN_OUTPUT"
    return 1
  fi

  local TOKEN_ID TOKEN_SECRET
  TOKEN_ID=$(echo "$TOKEN_LINE" | cut -d: -f2)
  TOKEN_SECRET=$(echo "$TOKEN_LINE" | cut -d: -f3)

  # Save credentials
  mkdir -p "$CRYPTO_DIR"
  jq -n \
    --arg url "https://${PROXMOX_IP}:8006/api2/json" \
    --arg token_id "$TOKEN_ID" \
    --arg token_secret "$TOKEN_SECRET" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      proxmox_api_url: $url,
      proxmox_api_token_id: $token_id,
      proxmox_api_token_secret: $token_secret,
      created_at: $created_at
    }' > "$CREDENTIALS_FILE"

  chmod 600 "$CREDENTIALS_FILE"
  success "API token created and saved to $CREDENTIALS_FILE"
}

# =============================================================================
# Configuration Generation
# =============================================================================

# Generate terraform.tfvars from bootstrap + discovery data.
# Single clean write — replaces the old 25+ sed_inplace operations.
#
# Reads: cluster-info.json, crypto/proxmox-credentials.json, bootstrap.yml
# Writes: terraform/terraform.tfvars
function generateTfvarsFromBootstrap() {
  doing "Generating terraform.tfvars..."

  local TFVARS_FILE="${SCRIPT_DIR}/terraform/terraform.tfvars"

  # Load API credentials
  local API_URL API_TOKEN_ID API_TOKEN_SECRET
  if [ -f "$CREDENTIALS_FILE" ]; then
    API_URL=$(jq -r '.proxmox_api_url // ""' "$CREDENTIALS_FILE")
    API_TOKEN_ID=$(jq -r '.proxmox_api_token_id // ""' "$CREDENTIALS_FILE")
    API_TOKEN_SECRET=$(jq -r '.proxmox_api_token_secret // ""' "$CREDENTIALS_FILE")
  fi

  # Build the bpg/proxmox API token string: "user@realm!token=secret"
  local BPG_API_TOKEN="${API_TOKEN_ID}=${API_TOKEN_SECRET}"

  # Calculate DNS IPs from network CIDR
  # Convention: .3 = VIP, .4-.6 = DNS nodes, .7+ = services
  local BASE_IP
  BASE_IP=$(echo "$NETWORK_CIDR" | cut -d/ -f1 | sed 's/\.[0-9]*$//')
  local DNS_PRIMARY="${BASE_IP}.4"

  # Build node IP map
  local NODE_IPS_HCL=""
  for i in "${!CLUSTER_NODES[@]}"; do
    NODE_IPS_HCL+="  ${CLUSTER_NODES[$i]} = \"${CLUSTER_NODE_IPS[$i]}\"\n"
  done

  # Build DNS main nodes list (one per cluster node, starting at .4)
  local DNS_NODES_HCL=""
  local dns_octet=4
  for i in "${!CLUSTER_NODES[@]}"; do
    local dns_ip="${BASE_IP}.${dns_octet}"
    DNS_NODES_HCL+="  {\n    hostname = \"dns-$(printf '%02d' $((i+1)))\"\n    ip       = \"${dns_ip}\"\n    target   = \"${CLUSTER_NODES[$i]}\"\n  },\n"
    dns_octet=$((dns_octet + 1))
  done

  cat > "$TFVARS_FILE" <<EOF
# =============================================================================
# Terraform Variables — Auto-generated by bootstrap
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source: bootstrap.yml + cluster discovery
# =============================================================================

# Proxmox API (bpg/proxmox provider)
proxmox_endpoint  = "${API_URL}"
proxmox_api_token = "${BPG_API_TOKEN}"

# Target node (primary)
proxmox_target_node = "${PRIMARY_NODE}"

# Network
network_gateway_address  = "${NETWORK_GATEWAY}"
network_interface_bridge  = "${NETWORK_BRIDGE}"
bootstrap_dns            = "${NETWORK_GATEWAY}"

# DNS
dns_postfix     = "${DNS_POSTFIX}"
dns_primary_ipv4 = "${DNS_PRIMARY}"

# Storage
template_storage = "${TEMPLATE_STORAGE}"
vm_storage       = "${RUNTIME_STORAGE}"
lxc_storage      = "${LXC_STORAGE}"

# Proxmox cluster nodes
proxmox_node_ips = {
$(echo -e "$NODE_IPS_HCL")}

# DNS main cluster nodes
dns_main_nodes = [
$(echo -e "$DNS_NODES_HCL")]
EOF

  success "terraform.tfvars generated"
}

# Generate packer.auto.pkrvars.hcl from bootstrap + discovery data.
# Single clean write — replaces the old 12+ sed_inplace operations.
#
# Reads: cluster-info.json, crypto/proxmox-credentials.json, bootstrap.yml
# Writes: packer/packer.auto.pkrvars.hcl
function generatePackerVarsFromBootstrap() {
  doing "Generating packer.auto.pkrvars.hcl..."

  local PACKER_FILE="${SCRIPT_DIR}/packer/packer.auto.pkrvars.hcl"

  # Load API credentials
  local API_URL API_TOKEN_ID API_TOKEN_SECRET
  if [ -f "$CREDENTIALS_FILE" ]; then
    API_URL=$(jq -r '.proxmox_api_url // ""' "$CREDENTIALS_FILE")
    API_TOKEN_ID=$(jq -r '.proxmox_api_token_id // ""' "$CREDENTIALS_FILE")
    API_TOKEN_SECRET=$(jq -r '.proxmox_api_token_secret // ""' "$CREDENTIALS_FILE")
  fi

  # Load Vault address if available
  local VAULT_ADDR=""
  if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
    VAULT_ADDR=$(jq -r '.vault_address // ""' "$VAULT_CREDENTIALS_FILE")
  fi

  # Load service passwords if available
  local ROOT_PASS="changeme123" SSH_PASS="changeme123" TEMPLATE_PASS="changeme123"
  local PASSWORDS_FILE="$CRYPTO_DIR/service-passwords.json"
  if [ -f "$PASSWORDS_FILE" ]; then
    ROOT_PASS=$(jq -r '.packer_root_password // "changeme123"' "$PASSWORDS_FILE")
    TEMPLATE_PASS=$(jq -r '.template_password // "changeme123"' "$PASSWORDS_FILE")
  fi

  cat > "$PACKER_FILE" <<EOF
# =============================================================================
# Packer Variables — Auto-generated by bootstrap
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source: bootstrap.yml + cluster discovery
# =============================================================================

# Proxmox API
proxmox_url           = "${API_URL}"
proxmox_node          = "${PRIMARY_NODE}"
proxmox_token_id      = "${API_TOKEN_ID}"
proxmox_token_secret  = "${API_TOKEN_SECRET}"

# DNS
dns_postfix = "${DNS_POSTFIX}"

# Storage
template_storage      = "${TEMPLATE_STORAGE}"
template_storage_type = "${TEMPLATE_STORAGE_TYPE}"

# Network
network_bridge = "${NETWORK_BRIDGE}"

# Template credentials
root_password = "${ROOT_PASS}"
ssh_password  = "${TEMPLATE_PASS}"

# Vault PKI (for root CA during builds — empty until Vault is deployed)
vault_addr = "${VAULT_ADDR}"
EOF

  chmod 600 "$PACKER_FILE"
  success "packer.auto.pkrvars.hcl generated"
}

# =============================================================================
# LXC Template Download
# =============================================================================

# Download required LXC templates to each Proxmox node.
# The lxc-pihole Terraform module needs a Debian 12 standard template.
#
# Globals read: PROXMOX_PASS, CLUSTER_NODES[], CLUSTER_NODE_IPS[]
function downloadLXCTemplates() {
  doing "Downloading LXC templates to Proxmox nodes..."

  local SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
  local LXC_TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"

  for i in "${!CLUSTER_NODE_IPS[@]}"; do
    local NODE_IP="${CLUSTER_NODE_IPS[$i]}"
    local NODE_NAME="${CLUSTER_NODES[$i]}"

    info "  Checking LXC templates on $NODE_NAME ($NODE_IP)..."

    # Check if template already exists
    local EXISTS
    EXISTS=$(sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$NODE_IP" \
      "pveam list local 2>/dev/null | grep -c 'debian-12-standard' || echo 0" 2>/dev/null)

    if [ "$EXISTS" -gt 0 ]; then
      info "    Debian 12 template already present on $NODE_NAME"
    else
      info "    Downloading $LXC_TEMPLATE to $NODE_NAME..."
      sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$NODE_IP" \
        "pveam update && pveam download local $LXC_TEMPLATE" 2>/dev/null

      if [ $? -eq 0 ]; then
        info "    Template downloaded successfully on $NODE_NAME"
      else
        warn "    Failed to download template on $NODE_NAME — trying latest available..."
        # Fall back to downloading whatever debian-12-standard is available
        local LATEST
        LATEST=$(sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$NODE_IP" \
          "pveam available --section system 2>/dev/null | grep 'debian-12-standard' | awk '{print \$2}' | tail -1" 2>/dev/null)
        if [ -n "$LATEST" ]; then
          sshpass -p "$PROXMOX_PASS" ssh $SSH_OPTS root@"$NODE_IP" \
            "pveam download local $LATEST" 2>/dev/null
          info "    Downloaded $LATEST on $NODE_NAME"
        else
          warn "    No Debian 12 template found in repository for $NODE_NAME"
        fi
      fi
    fi
  done

  success "LXC template check complete"
}

# =============================================================================
# Main Bootstrap Flow
# =============================================================================

# Run the full bootstrap sequence: read config → discover → generate
function runBootstrap() {
  cat <<EOF

############################################################################
Proxmox Lab Bootstrap

Reading bootstrap.yml, discovering cluster topology, and generating
configuration for Terraform and Packer.
#############################################################################

EOF

  _bootstrap_init_vars

  readBootstrapConfig || return 1
  discoverCluster || return 1
  discoverStorage || return 1
  discoverNetworkBridges || return 1
  createAPIToken || return 1
  downloadLXCTemplates || return 1
  generateTfvarsFromBootstrap || return 1
  generatePackerVarsFromBootstrap || return 1

  echo
  success "Bootstrap complete!"
  info "  Cluster:   ${#CLUSTER_NODES[@]} node(s) (${IS_CLUSTER})"
  info "  Storage:   templates=$TEMPLATE_STORAGE, runtime=$RUNTIME_STORAGE, lxc=$LXC_STORAGE"
  info "  Bridge:    $NETWORK_BRIDGE"
  info "  DNS:       $DNS_POSTFIX"
  info "  Terraform: terraform/terraform.tfvars"
  info "  Packer:    packer/packer.auto.pkrvars.hcl"
  echo
}
