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
  # Storage overrides from bootstrap.yml are used as defaults in the
  # interactive storage selection prompt (not auto-applied)
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
  info "  Storage:       ${STORAGE_TEMPLATES_OVERRIDE:-<interactive>}"

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
# Storage Selection
# =============================================================================

# Helper: present a numbered list of storage pools and let the user pick.
# Arguments: $1 = prompt text, $2 = jq-filtered JSON array of candidates,
#            $3 = default value (pre-selected if user presses Enter)
# Returns: selected storage name in $_SELECTED_STORAGE
function _selectStorage() {
  local prompt="$1" candidates="$2" default="$3"
  local names=() types=() shared_flags=()

  while IFS='|' read -r name type is_shared; do
    names+=("$name")
    types+=("$type")
    shared_flags+=("$is_shared")
  done < <(echo "$candidates" | jq -r '[.[] | {storage, type, shared}] | sort_by(.storage) | .[] | "\(.storage)|\(.type)|\(.shared)"')

  if [ ${#names[@]} -eq 0 ]; then
    warn "  No suitable storage pools found"
    _SELECTED_STORAGE=""
    return 1
  fi

  # Find default index
  local default_idx=""
  for i in "${!names[@]}"; do
    [ "${names[$i]}" = "$default" ] && default_idx=$i
  done

  echo
  echo "  $prompt"
  for i in "${!names[@]}"; do
    local label="${names[$i]} (${types[$i]})"
    [ "${shared_flags[$i]}" = "1" ] && label+=" [shared]"
    local marker=""
    [ "$i" = "$default_idx" ] && marker=" (default)"
    echo "    $((i+1))) ${label}${marker}"
  done

  local selection
  if [ -n "$default_idx" ]; then
    read -rp "$(question "  Select [1-${#names[@]}] (default: $((default_idx+1))): ")" selection
    selection=${selection:-$((default_idx+1))}
  else
    read -rp "$(question "  Select [1-${#names[@]}]: ")" selection
  fi

  # Validate
  if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#names[@]} ]; then
    if [ -n "$default_idx" ]; then
      selection=$((default_idx+1))
      warn "  Invalid selection — using default: ${names[$default_idx]}"
    else
      warn "  Invalid selection — using first option: ${names[0]}"
      selection=1
    fi
  fi

  _SELECTED_STORAGE="${names[$((selection-1))]}"
}

# Discover available storage pools from Proxmox and prompt the user to
# select which pools to use for templates, VMs, and LXC containers.
#
# Snippet and vztmpl storage are auto-detected (not user-facing choices)
# since they require specific content types that limit the options.
#
# Globals set: TEMPLATE_STORAGE, TEMPLATE_STORAGE_TYPE, RUNTIME_STORAGE,
#              LXC_STORAGE, SNIPPET_STORAGE
function discoverStorage() {
  doing "Discovering storage pools..."

  # Check if storage was already selected in a previous run
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local saved_templates saved_type saved_runtime saved_lxc saved_snippets saved_vztmpl
    saved_templates=$(jq -r '.storage.templates // empty' "$CLUSTER_INFO_FILE")
    saved_type=$(jq -r '.storage.templates_type // empty' "$CLUSTER_INFO_FILE")
    saved_runtime=$(jq -r '.storage.runtime // empty' "$CLUSTER_INFO_FILE")
    saved_lxc=$(jq -r '.storage.lxc // empty' "$CLUSTER_INFO_FILE")
    saved_snippets=$(jq -r '.storage.snippets // empty' "$CLUSTER_INFO_FILE")
    saved_vztmpl=$(jq -r '.storage.vztmpl // empty' "$CLUSTER_INFO_FILE")

    if [ -n "$saved_templates" ] && [ -n "$saved_runtime" ] && [ -n "$saved_lxc" ]; then
      info "  Previous storage selection found:"
      info "    Templates:       $saved_templates ($saved_type)"
      info "    Operational VMs: $saved_runtime"
      info "    Operational LXC: $saved_lxc"
      info "    Snippets:        $saved_snippets"
      info "    LXC templates:   $saved_vztmpl"

      read -rp "$(question "  Keep these settings? [Y/n]: ")" keep_storage
      keep_storage=${keep_storage:-Y}
      if [[ "$keep_storage" =~ ^[Yy]$ ]]; then
        TEMPLATE_STORAGE="$saved_templates"
        TEMPLATE_STORAGE_TYPE="$saved_type"
        RUNTIME_STORAGE="$saved_runtime"
        LXC_STORAGE="$saved_lxc"
        SNIPPET_STORAGE="$saved_snippets"
        VZTMPL_STORAGE="$saved_vztmpl"
        success "Storage configuration loaded from previous run"
        return 0
      fi
    fi
  fi

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
    SNIPPET_STORAGE="local"
    return 0
  fi

  # Show all storage pools with their content types (sorted alphabetically)
  info "  Available storage pools:"
  echo "$STORAGE_JSON" | jq -r '[.[] | {storage, type, shared, content}] | sort_by(.storage) | .[] | "    \(.storage) (\(.type)) \(if .shared == 1 then "[shared]" else "[local]" end) content: \(.content)"'

  # Filter storage pools that can hold VM disk images
  local IMAGE_STORAGE
  IMAGE_STORAGE=$(echo "$STORAGE_JSON" | jq '[.[] | select(.content | contains("images"))]')

  # --- Auto-detect snippet and vztmpl storage (limited choices) ---

  # Identify storage that supports snippets (needed for cloud-init cicustom)
  # Prefer shared snippet storage for clusters so templates work on any node
  # Not local — needed by generatePackerVarsFromBootstrap
  SNIPPET_STORAGE=""
  if [ "$IS_CLUSTER" = "true" ]; then
    SNIPPET_STORAGE=$(echo "$STORAGE_JSON" | jq -r '[.[] | select((.content | contains("snippets")) and .shared == 1)] | first | .storage // empty')
  fi
  if [ -z "$SNIPPET_STORAGE" ]; then
    SNIPPET_STORAGE=$(echo "$STORAGE_JSON" | jq -r '[.[] | select(.content | contains("snippets"))] | first | .storage // empty')
  fi
  if [ -n "$SNIPPET_STORAGE" ]; then
    info "  Snippet storage: $SNIPPET_STORAGE$([ "$IS_CLUSTER" = "true" ] && echo " (shared)" || echo "")"
  else
    SNIPPET_STORAGE="local"
    warn "  No storage with 'snippets' content found — falling back to 'local'"
  fi

  # Identify storage that supports LXC templates (vztmpl)
  # Prefer shared storage for clusters so templates are accessible on all nodes
  # Not local — needed by downloadLXCTemplates
  VZTMPL_STORAGE=""
  if [ "$IS_CLUSTER" = "true" ]; then
    VZTMPL_STORAGE=$(echo "$STORAGE_JSON" | jq -r '[.[] | select((.content | contains("vztmpl")) and .shared == 1)] | sort_by(.storage) | first | .storage // empty')
  fi
  if [ -z "$VZTMPL_STORAGE" ]; then
    VZTMPL_STORAGE=$(echo "$STORAGE_JSON" | jq -r '[.[] | select(.content | contains("vztmpl"))] | sort_by(.storage) | first | .storage // empty')
  fi
  if [ -n "$VZTMPL_STORAGE" ]; then
    info "  LXC template storage: $VZTMPL_STORAGE"
  else
    warn "  No storage with 'vztmpl' content found — LXC template downloads may fail"
  fi

  # --- Storage selection ---
  #
  # Priority: bootstrap.yml > cluster-info.json > interactive prompt
  # If bootstrap.yml has both templates and runtime, use them directly.
  # If cluster-info.json has saved selections, offer to keep them.
  # Otherwise, prompt interactively.

  local resolved_template="" resolved_vm="" resolved_lxc=""

  # Check bootstrap.yml first — explicit config skips all prompts
  if [ -n "$STORAGE_TEMPLATES_OVERRIDE" ] && [ -n "$STORAGE_RUNTIME_OVERRIDE" ]; then
    resolved_template="$STORAGE_TEMPLATES_OVERRIDE"
    resolved_vm="$STORAGE_RUNTIME_OVERRIDE"
    # LXC uses runtime storage unless it's file-level
    local runtime_type
    runtime_type=$(echo "$IMAGE_STORAGE" | jq -r --arg s "$resolved_vm" '.[] | select(.storage == $s) | .type // "lvm"')
    if [[ "$runtime_type" =~ ^(nfs|cifs|glusterfs)$ ]]; then
      # Runtime is file-level — pick first block-level storage
      resolved_lxc=$(echo "$IMAGE_STORAGE" | jq -r '[.[] | select(.type | test("^(nfs|cifs|glusterfs)$") | not)] | sort_by(.storage) | first | .storage // "local-lvm"')
    else
      resolved_lxc="$resolved_vm"
    fi
    TEMPLATE_STORAGE="$resolved_template"
    TEMPLATE_STORAGE_TYPE=$(echo "$IMAGE_STORAGE" | jq -r --arg s "$TEMPLATE_STORAGE" '.[] | select(.storage == $s) | .type // "lvm"')
    RUNTIME_STORAGE="$resolved_vm"
    LXC_STORAGE="$resolved_lxc"
    info "  Templates:       $TEMPLATE_STORAGE ($TEMPLATE_STORAGE_TYPE) — from bootstrap.yml"
    info "  Operational VMs: $RUNTIME_STORAGE — from bootstrap.yml"
    info "  Operational LXC: $LXC_STORAGE"
  else
    # Fall back to interactive selection with saved defaults

    local default_template="" default_vm="" default_lxc=""

    # Load previous selections as defaults
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      default_template=$(jq -r '.storage.templates // empty' "$CLUSTER_INFO_FILE")
      default_vm=$(jq -r '.storage.runtime // empty' "$CLUSTER_INFO_FILE")
      default_lxc=$(jq -r '.storage.lxc // empty' "$CLUSTER_INFO_FILE")
    fi

    # bootstrap.yml partial overrides
    [ -z "$default_template" ] && [ -n "$STORAGE_TEMPLATES_OVERRIDE" ] && default_template="$STORAGE_TEMPLATES_OVERRIDE"
    [ -z "$default_vm" ] && [ -n "$STORAGE_RUNTIME_OVERRIDE" ] && default_vm="$STORAGE_RUNTIME_OVERRIDE"

    # Heuristic defaults
    if [ -z "$default_template" ]; then
      if [ "$IS_CLUSTER" = "true" ]; then
        default_template=$(echo "$IMAGE_STORAGE" | jq -r '[.[] | select(.shared == 1)] | sort_by(.storage) | first | .storage // empty')
      fi
      [ -z "$default_template" ] && default_template="local-lvm"
    fi
    [ -z "$default_vm" ] && default_vm="local-lvm"
    [ -z "$default_lxc" ] && default_lxc="local-lvm"

    # 1) Template storage
    _selectStorage "Select storage for Packer templates (VM images, LXC templates):" "$IMAGE_STORAGE" "$default_template"
    TEMPLATE_STORAGE="$_SELECTED_STORAGE"
    TEMPLATE_STORAGE_TYPE=$(echo "$IMAGE_STORAGE" | jq -r --arg s "$TEMPLATE_STORAGE" '.[] | select(.storage == $s) | .type // "lvm"')
    info "  Templates: $TEMPLATE_STORAGE ($TEMPLATE_STORAGE_TYPE)"

    # 2) Operational VM storage
    _selectStorage "Select storage for operational VMs (Nomad cluster, Kasm):" "$IMAGE_STORAGE" "$default_vm"
    RUNTIME_STORAGE="$_SELECTED_STORAGE"
    info "  Operational VMs: $RUNTIME_STORAGE"

    # 3) Operational LXC storage (file-level excluded)
    local LXC_CANDIDATES
    LXC_CANDIDATES=$(echo "$IMAGE_STORAGE" | jq '[.[] | select(.type | test("^(nfs|cifs|glusterfs)$") | not)]')
    local lxc_count
    lxc_count=$(echo "$LXC_CANDIDATES" | jq 'length')

    if [ "$lxc_count" -eq 1 ]; then
      LXC_STORAGE=$(echo "$LXC_CANDIDATES" | jq -r '.[0].storage')
      info "  Operational LXC: $LXC_STORAGE (only block-level option)"
    elif [ "$lxc_count" -gt 1 ]; then
      local lxc_default="$default_lxc"
      local lxc_default_type
      lxc_default_type=$(echo "$IMAGE_STORAGE" | jq -r --arg s "$lxc_default" '.[] | select(.storage == $s) | .type // "lvm"')
      if [[ "$lxc_default_type" =~ ^(nfs|cifs|glusterfs)$ ]]; then
        lxc_default="local-lvm"
      fi
      _selectStorage "Select storage for operational LXC containers (file-level storage excluded):" "$LXC_CANDIDATES" "$lxc_default"
      LXC_STORAGE="$_SELECTED_STORAGE"
      info "  Operational LXC: $LXC_STORAGE"
    else
      LXC_STORAGE="local-lvm"
      warn "  No block-level storage found for LXC — using local-lvm"
    fi
  fi

  # Save storage config to cluster-info.json
  SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
  VZTMPL_STORAGE="${VZTMPL_STORAGE:-local}"

  local tmp; tmp=$(mktemp)
  jq --arg ts "$TEMPLATE_STORAGE" --arg tt "$TEMPLATE_STORAGE_TYPE" \
    --arg rs "$RUNTIME_STORAGE" --arg ls "$LXC_STORAGE" \
    --arg ss "$SNIPPET_STORAGE" --arg vs "$VZTMPL_STORAGE" \
    --argjson shared "$([ "$IS_CLUSTER" = "true" ] && echo "true" || echo "false")" \
    '.storage = {
      templates: $ts,
      templates_type: $tt,
      runtime: $rs,
      lxc: $ls,
      snippets: $ss,
      vztmpl: $vs,
      is_shared: $shared
    }' "$CLUSTER_INFO_FILE" > "$tmp" && mv "$tmp" "$CLUSTER_INFO_FILE"

  success "Storage selection complete"
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
    USER="hashicorp@pam"
    ROLE="HashicorpBuild"
    TOKEN_NAME="hashicorp-token"

    # Clean up existing user/role/acl if present
    pveum user delete "$USER" 2>/dev/null || true
    pveum role delete "$ROLE" 2>/dev/null || true

    # Create role with required privileges
    # VM.GuestAgent.* = Packer needs guest agent access to discover VM IP for SSH
    pveum role add "$ROLE" -privs "Sys.Audit,Sys.Console,Sys.Modify,Sys.PowerMgmt,SDN.Use,Pool.Allocate,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.GuestAgent.Audit,VM.GuestAgent.Unrestricted,VM.Migrate,VM.PowerMgmt,VM.Snapshot"

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
  local BASE_IP CIDR_MASK
  BASE_IP=$(echo "$NETWORK_CIDR" | cut -d/ -f1 | sed 's/\.[0-9]*$//')
  CIDR_MASK=$(echo "$NETWORK_CIDR" | grep -oE '[0-9]+$')
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
    DNS_NODES_HCL+="  {\n    hostname    = \"dns-$(printf '%02d' $((i+1)))\"\n    target_node = \"${CLUSTER_NODES[$i]}\"\n    ip          = \"${dns_ip}/${CIDR_MASK}\"\n    gw          = \"${NETWORK_GATEWAY}\"\n  },\n"
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
lxc_ostemplate   = "${VZTMPL_STORAGE}:vztmpl/${LXC_DEFAULT_TEMPLATE}"

# Proxmox cluster nodes
proxmox_node_ips = {
$(echo -e "$NODE_IPS_HCL")}

# DNS main cluster nodes
dns_main_nodes = [
$(echo -e "$DNS_NODES_HCL")]

# Vault — credentials written to terraform/vault.auto.tfvars after Vault deploys
# (empty defaults here so terraform validate works before Vault exists)
vault_address = ""
vault_token   = ""
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

# Cloud-init snippet storage (shared — for qemu-guest-agent install)
snippet_storage = "${SNIPPET_STORAGE}"

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

# Download a single LXC template with progress display.
# Uses sshRun (enterprise SSH key) — called after bootstrap when keys are distributed.
# Arguments: $1=node_ip, $2=node_name, $3=storage, $4=search_pattern, $5=filename
# Returns: 0 on success (template verified), 1 on failure
function _downloadOneTemplate() {
  local node_ip="$1" node_name="$2" storage="$3" pattern="$4" filename="$5"
  local display_name="${filename%%_*}"  # e.g. "debian-12-standard"

  # Check if already present
  local template_list
  template_list=$(sshRun "$REMOTE_USER" "$node_ip" "pveam list ${storage}" 2>/dev/null | tail -n +2) || template_list=""

  if echo "$template_list" | grep -q "$pattern"; then
    success "    $display_name — already present"
    return 0
  fi

  # Download (capture output to log, show spinner)
  doing "    $display_name — downloading..."
  local log_file
  log_file=$(mktemp)

  sshRun "$REMOTE_USER" "$node_ip" "pveam download ${storage} $filename 2>&1" > "$log_file" 2>&1 || true

  # Verify the template actually landed — don't trust exit codes
  local verify_list
  verify_list=$(sshRun "$REMOTE_USER" "$node_ip" "pveam list ${storage}" 2>/dev/null | tail -n +2) || verify_list=""

  if echo "$verify_list" | grep -q "$pattern"; then
    success "    $display_name — done"
    rm -f "$log_file"
    return 0
  fi

  # Exact filename failed — try latest available version
  warn "    $display_name — exact version not found, trying latest..."
  local latest
  latest=$(sshRun "$REMOTE_USER" "$node_ip" \
    "pveam available --section system 2>/dev/null | grep '$pattern' | awk '{print \$2}' | tail -1" 2>/dev/null)

  if [ -n "$latest" ]; then
    sshRun "$REMOTE_USER" "$node_ip" "pveam download ${storage} $latest 2>&1" > "$log_file" 2>&1 || true

    verify_list=$(sshRun "$REMOTE_USER" "$node_ip" "pveam list ${storage}" 2>/dev/null | tail -n +2) || verify_list=""

    if echo "$verify_list" | grep -q "$pattern"; then
      success "    $display_name — done ($latest)"
      rm -f "$log_file"
      return 0
    fi
  fi

  # Failed — show the download log so user can see why
  error "    $display_name — download failed"
  if [ -s "$log_file" ]; then
    warn "    Download output:"
    sed 's/^/      /' "$log_file"
  fi
  rm -f "$log_file"
  return 1
}

# Download required LXC templates (Debian for Pi-hole containers).
# Uses enterprise SSH key — must be called after bootstrap distributes keys.
# Uses shared storage detection to avoid redundant downloads on clusters.
#
# Globals read: REMOTE_USER, CLUSTER_NODES[], CLUSTER_NODE_IPS[],
#               LXC_TEMPLATES[], VZTMPL_STORAGE
function downloadLXCTemplates() {
  doing "Downloading LXC templates..."

  # Load VZTMPL_STORAGE from cluster-info.json if not set
  if [ -z "${VZTMPL_STORAGE:-}" ] && [ -f "$CLUSTER_INFO_FILE" ]; then
    VZTMPL_STORAGE=$(jq -r '.storage.vztmpl // "local"' "$CLUSTER_INFO_FILE")
  fi
  local STORAGE="${VZTMPL_STORAGE:-local}"

  # Ensure cluster context is loaded
  if [ ${#CLUSTER_NODE_IPS[@]} -eq 0 ]; then
    ensureClusterContext || return 1
  fi

  # Update the template index first (once, on primary node)
  sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" "pveam update" >/dev/null 2>&1 || warn "  Could not update template index"

  # Detect if storage is shared (only need to download once)
  local check_all=true
  local storage_shared
  storage_shared=$(sshRun "$REMOTE_USER" "${CLUSTER_NODE_IPS[0]}" \
    "pvesh get /storage/${STORAGE} --output-format json 2>/dev/null | jq -r '.shared // 0'" 2>/dev/null)
  if [ "$storage_shared" = "1" ]; then
    check_all=false
    info "  Storage '$STORAGE' is shared — downloading to primary node only"
  fi

  local any_failed=false

  for i in "${!CLUSTER_NODE_IPS[@]}"; do
    local NODE_IP="${CLUSTER_NODE_IPS[$i]}"
    local NODE_NAME="${CLUSTER_NODES[$i]}"

    # For shared storage, skip nodes after the first
    if [ "$check_all" = false ] && [ "$i" -gt 0 ]; then
      continue
    fi

    info "  $NODE_NAME ($NODE_IP):"

    for entry in "${LXC_TEMPLATES[@]}"; do
      local pattern="${entry%%|*}"
      local filename="${entry##*|}"

      if ! _downloadOneTemplate "$NODE_IP" "$NODE_NAME" "$STORAGE" "$pattern" "$filename"; then
        any_failed=true
      fi
    done
  done

  if [ "$any_failed" = true ]; then
    error "  Some templates failed to download. Check DNS/internet on your Proxmox nodes."
    return 1
  fi

  success "LXC templates ready"
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

  # Remove completion marker — must finish all steps to re-mark as complete
  rm -f "$SCRIPT_DIR/.bootstrap-complete"

  # Remove stale Vault files from previous deployments — if Vault
  # doesn't exist yet, these would make Terraform/Packer try to connect to it
  if [ -f "$SCRIPT_DIR/terraform/vault.auto.tfvars" ]; then
    warn "Removing stale vault.auto.tfvars from previous deployment"
    rm -f "$SCRIPT_DIR/terraform/vault.auto.tfvars"
  fi
  if [ -f "$VAULT_CREDENTIALS_FILE" ]; then
    warn "Removing stale vault-credentials.json from previous deployment"
    rm -f "$VAULT_CREDENTIALS_FILE"
  fi

  readBootstrapConfig || return 1
  discoverCluster || return 1
  discoverStorage || return 1
  discoverNetworkBridges || return 1
  createAPIToken || return 1
  generateTfvarsFromBootstrap || return 1
  generatePackerVarsFromBootstrap || return 1

  # Mark bootstrap as successfully completed
  date -u +%Y-%m-%dT%H:%M:%SZ > "$SCRIPT_DIR/.bootstrap-complete"

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
