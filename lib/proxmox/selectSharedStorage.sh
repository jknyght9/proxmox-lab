#!/usr/bin/env bash

# Ensures shared storage is selected for multi-node clusters
function ensureSharedStorage() {
  if [ -z "$TEMPLATE_STORAGE" ]; then
    selectSharedStorage || return 1
  fi

  # For clusters, verify shared storage is selected
  if [ "$IS_CLUSTER" = "true" ] && [ "$USE_SHARED_STORAGE" != "true" ]; then
    warn "Multi-node cluster requires shared storage. Current: $TEMPLATE_STORAGE (local)"
    warn "You need to select shared storage (NFS, Ceph, etc.)"
    echo

    # Clear existing storage config to force re-selection
    TEMPLATE_STORAGE=""
    TEMPLATE_STORAGE_TYPE=""
    USE_SHARED_STORAGE=""

    # Remove storage from cluster-info.json to allow re-selection
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      local tmp_file=$(mktemp)
      jq 'del(.storage)' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"
    fi

    # Now run storage selection (won't skip because we cleared it)
    selectSharedStorage || return 1

    # Save the new storage config
    local tmp_file=$(mktemp)
    jq --arg storage "$TEMPLATE_STORAGE" \
       --arg storage_type "${TEMPLATE_STORAGE_TYPE:-lvm}" \
       --argjson shared "$USE_SHARED_STORAGE" \
       '. + { storage: { selected: $storage, type: $storage_type, is_shared: $shared } }' \
       "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"
  fi

  info "Using storage: $TEMPLATE_STORAGE ($TEMPLATE_STORAGE_TYPE)"
}

function selectSharedStorage() {
  # Check if storage is already configured in cluster-info.json
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local EXISTING_STORAGE
    EXISTING_STORAGE=$(jq -r '.storage.selected // ""' "$CLUSTER_INFO_FILE")
    TEMPLATE_STORAGE_TYPE=$(jq -r '.storage.type // "lvm"' "$CLUSTER_INFO_FILE")
    if [ -n "$EXISTING_STORAGE" ] && [ "$EXISTING_STORAGE" != "null" ]; then
      TEMPLATE_STORAGE="$EXISTING_STORAGE"
      USE_SHARED_STORAGE=$(jq -r '.storage.is_shared // false' "$CLUSTER_INFO_FILE")
      export TEMPLATE_STORAGE
      export TEMPLATE_STORAGE_TYPE
      export USE_SHARED_STORAGE
      success "Using configured storage: $TEMPLATE_STORAGE ($TEMPLATE_STORAGE_TYPE, shared: $USE_SHARED_STORAGE)"
      return 0
    fi
  fi

  doing "Detecting available storage..."

  # Get storage list from first node
  local STORAGE_JSON
  STORAGE_JSON=$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "pvesh get /storage --output-format json")

  # Build arrays of storage info (name, type, shared)
  local STORAGE_NAMES=()
  local STORAGE_TYPES=()
  local STORAGE_SHARED=()

  # For clusters: only show shared storage that supports VM images
  # For single-node: show all storage that supports VM images
  local JQ_FILTER
  if [ "$IS_CLUSTER" = "true" ]; then
    JQ_FILTER='.[] | select(.shared == 1 and (.content | contains("images")))'
  else
    JQ_FILTER='.[] | select(.content | contains("images"))'
  fi

  while IFS='|' read -r name type shared; do
    if [[ -n "$name" ]]; then
      STORAGE_NAMES+=("$name")
      STORAGE_TYPES+=("${type:-unknown}")
      STORAGE_SHARED+=("$shared")
    fi
  done < <(echo "$STORAGE_JSON" | jq -r "[$JQ_FILTER] | sort_by(.storage) | .[] | \"\(.storage)|\(.type // \"unknown\")|\(.shared // 0)\"")

  if [ ${#STORAGE_NAMES[@]} -gt 0 ]; then
    echo
    info "Storage Selection for VM Templates"
    if [ "$IS_CLUSTER" = "true" ]; then
      info "Multi-node cluster detected - showing shared storage only"
    fi
    echo
    info "Available storage:"
    for i in "${!STORAGE_NAMES[@]}"; do
      local shared_label=""
      if [ "${STORAGE_SHARED[$i]}" = "1" ]; then
        shared_label="[shared]"
      else
        shared_label="[local]"
      fi
      echo "    $((i + 1)). ${STORAGE_NAMES[$i]} (${STORAGE_TYPES[$i]}) $shared_label"
    done
    echo

    local DEFAULT_STORE="${STORAGE_NAMES[0]}"
    read -rp "$(question "Select storage [1]: ")" STORAGE_CHOICE
    STORAGE_CHOICE=${STORAGE_CHOICE:-1}

    # Check if user entered a number or a name
    if [[ "$STORAGE_CHOICE" =~ ^[0-9]+$ ]]; then
      local idx=$((STORAGE_CHOICE - 1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#STORAGE_NAMES[@]}" ]; then
        TEMPLATE_STORAGE="${STORAGE_NAMES[$idx]}"
        TEMPLATE_STORAGE_TYPE="${STORAGE_TYPES[$idx]}"
        USE_SHARED_STORAGE=$([ "${STORAGE_SHARED[$idx]}" = "1" ] && echo true || echo false)
      else
        error "Invalid selection"
        return 1
      fi
    else
      # Assume they typed the storage name - look it up
      local found=false
      for i in "${!STORAGE_NAMES[@]}"; do
        if [ "${STORAGE_NAMES[$i]}" = "$STORAGE_CHOICE" ]; then
          TEMPLATE_STORAGE="${STORAGE_NAMES[$i]}"
          TEMPLATE_STORAGE_TYPE="${STORAGE_TYPES[$i]}"
          USE_SHARED_STORAGE=$([ "${STORAGE_SHARED[$i]}" = "1" ] && echo true || echo false)
          found=true
          break
        fi
      done
      if [ "$found" = false ]; then
        error "Storage '$STORAGE_CHOICE' not found"
        return 1
      fi
    fi
  else
    if [ "$IS_CLUSTER" = "true" ]; then
      error "No shared storage found! Multi-node clusters require shared storage (NFS, Ceph, etc.)"
      error "Please configure shared storage in Proxmox before continuing."
      return 1
    else
      warn "No VM-compatible storage found. Using local-lvm"
      TEMPLATE_STORAGE="local-lvm"
      TEMPLATE_STORAGE_TYPE="lvm"
      USE_SHARED_STORAGE=false
    fi
  fi

  export TEMPLATE_STORAGE
  export TEMPLATE_STORAGE_TYPE
  export USE_SHARED_STORAGE
  success "Using storage: $TEMPLATE_STORAGE ($TEMPLATE_STORAGE_TYPE, shared: $USE_SHARED_STORAGE)"
}