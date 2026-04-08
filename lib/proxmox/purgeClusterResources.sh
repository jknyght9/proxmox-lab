#!/usr/bin/env bash

# Comprehensive cluster-wide resource purge
# Scans all Proxmox nodes for project VMs/LXCs and offers to destroy them
function purgeClusterResources() {
  local AUTO_PURGE=false
  local PURGE_TERRAFORM=true
  local LXC_ONLY=false
  local INCLUDE_TEMPLATES=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto) AUTO_PURGE=true; shift ;;
      --no-terraform) PURGE_TERRAFORM=false; shift ;;
      --lxc-only) LXC_ONLY=true; shift ;;
      --include-templates) INCLUDE_TEMPLATES=true; shift ;;
      *) shift ;;
    esac
  done

  doing "Scanning all cluster nodes for existing project resources..."

  # Ensure cluster info is loaded
  if [ ${#CLUSTER_NODE_IPS[@]} -eq 0 ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      loadClusterInfo
    else
      error "No cluster information available. Run setup first."
      return 1
    fi
  fi

  # Define project VMID ranges
  # LXC containers (902 was step-ca, now retired - CA is in Vault PKI)
  local LXC_VMIDS=(
    902         # legacy step-ca (kept for cleanup of old deployments)
    909         # legacy (kept for cleanup of old deployments)
    910 911 912 # dns-main (dns-01, dns-02, dns-03)
    920 921 922 # dns-labnet (labnet-dns-01, labnet-dns-02, labnet-dns-03)
  )

  # QEMU VMs (excluding Packer templates - handled separately)
  local VM_VMIDS=(
    903 904           # docker-swarm managers
    905 906 907       # nomad cluster
    908 930           # kasm
  )

  # Packer templates (separate so user can choose)
  # NOTE: Only includes project-generated templates, NOT base cloud-init images
  # (9997-9999 are user-provided base images that Packer clones from)
  local TEMPLATE_VMIDS=(
    9001              # docker-template
    9002              # nomad-template
  )

  # Collect findings
  local FOUND_LXC=()
  local FOUND_VM=()
  local FOUND_TEMPLATES=()
  local FOUND_NODES=()

  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"

    info "  Scanning $node ($ip)..."

    # Check LXC containers
    for vmid in "${LXC_VMIDS[@]}"; do
      if sshRun "$REMOTE_USER" "$ip" "pct status $vmid" &>/dev/null 2>&1; then
        local name
        name=$(sshRun "$REMOTE_USER" "$ip" "pct config $vmid 2>/dev/null | grep -oP 'hostname: \K.*'" 2>/dev/null || echo "unknown")
        FOUND_LXC+=("$vmid|$node|$ip|$name")
      fi
    done

    # Check QEMU VMs (skip if --lxc-only)
    if [ "$LXC_ONLY" != "true" ]; then
      for vmid in "${VM_VMIDS[@]}"; do
        if sshRun "$REMOTE_USER" "$ip" "qm status $vmid" &>/dev/null 2>&1; then
          local name
          name=$(sshRun "$REMOTE_USER" "$ip" "qm config $vmid 2>/dev/null | grep -oP 'name: \K.*'" 2>/dev/null || echo "unknown")
          FOUND_VM+=("$vmid|$node|$ip|$name")
        fi
      done

      # Check Packer templates (only add if not already found - shared storage means one copy)
      for vmid in "${TEMPLATE_VMIDS[@]}"; do
        # Skip if we already found this template on another node
        local already_found=false
        if [ ${#FOUND_TEMPLATES[@]} -gt 0 ]; then
          for entry in "${FOUND_TEMPLATES[@]}"; do
            [[ "$entry" == "$vmid|"* ]] && already_found=true && break
          done
        fi
        [ "$already_found" = true ] && continue

        if sshRun "$REMOTE_USER" "$ip" "qm status $vmid" &>/dev/null 2>&1; then
          local name
          name=$(sshRun "$REMOTE_USER" "$ip" "qm config $vmid 2>/dev/null | grep -oP 'name: \K.*'" 2>/dev/null || echo "unknown")
          FOUND_TEMPLATES+=("$vmid|$node|$ip|$name")
        fi
      done
    fi
  done

  # Report findings
  local total_found=$(( ${#FOUND_LXC[@]} + ${#FOUND_VM[@]} ))
  local total_with_templates=$(( total_found + ${#FOUND_TEMPLATES[@]} ))

  if [ $total_with_templates -eq 0 ]; then
    success "No existing project resources found on cluster"
    return 0
  fi

  echo
  warn "Found $total_with_templates existing project resource(s):"
  echo

  if [ ${#FOUND_LXC[@]} -gt 0 ]; then
    echo "  LXC Containers:"
    printf "  %-8s %-12s %-15s %s\n" "VMID" "Node" "IP" "Hostname"
    printf "  %-8s %-12s %-15s %s\n" "----" "----" "--" "--------"
    for entry in "${FOUND_LXC[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      printf "  %-8s %-12s %-15s %s\n" "$vmid" "$node" "$ip" "$name"
    done
    echo
  fi

  if [ ${#FOUND_VM[@]} -gt 0 ]; then
    echo "  QEMU VMs:"
    printf "  %-8s %-12s %-15s %s\n" "VMID" "Node" "IP" "Name"
    printf "  %-8s %-12s %-15s %s\n" "----" "----" "--" "----"
    for entry in "${FOUND_VM[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      printf "  %-8s %-12s %-15s %s\n" "$vmid" "$node" "$ip" "$name"
    done
    echo
  fi

  if [ ${#FOUND_TEMPLATES[@]} -gt 0 ]; then
    echo "  Packer Templates:"
    printf "  %-8s %-12s %-15s %s\n" "VMID" "Node" "IP" "Name"
    printf "  %-8s %-12s %-15s %s\n" "----" "----" "--" "----"
    for entry in "${FOUND_TEMPLATES[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      printf "  %-8s %-12s %-15s %s\n" "$vmid" "$node" "$ip" "$name"
    done
    echo
  fi

  # Confirm purge of LXC/VMs
  local do_purge=false
  if [ "$AUTO_PURGE" = true ]; then
    do_purge=true
  else
    if [ $total_found -gt 0 ]; then
      read -rp "$(question "Destroy LXC containers and VMs? [y/N]: ")" confirm
      [[ "$confirm" =~ ^[Yy]$ ]] && do_purge=true
    fi
  fi

  # Prompt for template removal (separate decision)
  local do_purge_templates=false
  if [ ${#FOUND_TEMPLATES[@]} -gt 0 ]; then
    if [ "$INCLUDE_TEMPLATES" = true ]; then
      do_purge_templates=true
    elif [ "$AUTO_PURGE" != true ]; then
      read -rp "$(question "Also remove Packer templates (9001, 9002)? These take time to rebuild. [y/N]: ")" confirm_templates
      [[ "$confirm_templates" =~ ^[Yy]$ ]] && do_purge_templates=true
    fi
  fi

  if [ "$do_purge" = false ] && [ "$do_purge_templates" = false ]; then
    warn "Skipping purge. Existing resources may cause deployment conflicts."
    return 1
  fi

  # Purge LXC containers
  if [ "$do_purge" = true ] && [ ${#FOUND_LXC[@]} -gt 0 ]; then
    doing "Destroying LXC containers..."
    for entry in "${FOUND_LXC[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      info "  Destroying LXC $vmid ($name) on $node..."
      sshRun "$REMOTE_USER" "$ip" "pct stop $vmid 2>/dev/null || true; pct destroy $vmid --purge 2>/dev/null || pct destroy $vmid 2>/dev/null || true"
    done
  fi

  # Purge QEMU VMs
  if [ "$do_purge" = true ] && [ ${#FOUND_VM[@]} -gt 0 ]; then
    doing "Destroying QEMU VMs..."
    for entry in "${FOUND_VM[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      info "  Destroying VM $vmid ($name) on $node..."
      sshRun "$REMOTE_USER" "$ip" "qm stop $vmid 2>/dev/null || true; qm destroy $vmid --purge 2>/dev/null || qm destroy $vmid 2>/dev/null || true"
    done
  fi

  # Purge Packer templates
  if [ "$do_purge_templates" = true ] && [ ${#FOUND_TEMPLATES[@]} -gt 0 ]; then
    doing "Destroying Packer templates..."
    for entry in "${FOUND_TEMPLATES[@]}"; do
      IFS='|' read -r vmid node ip name <<< "$entry"
      info "  Destroying template $vmid ($name) on $node..."
      sshRun "$REMOTE_USER" "$ip" "qm stop $vmid 2>/dev/null || true; qm destroy $vmid --purge 2>/dev/null || qm destroy $vmid 2>/dev/null || true"
    done
  fi

  # Clean Terraform state
  if [ "$PURGE_TERRAFORM" = true ] && [ "$do_purge" = true ]; then
    doing "Cleaning Terraform state..."
    (
      cd terraform
      # Remove all tracked resources from state
      docker compose run --rm terraform state list 2>/dev/null | while read -r resource; do
        docker compose run --rm terraform state rm "$resource" 2>/dev/null || true
      done
    ) 2>/dev/null || true
    info "  Terraform state cleared"
  fi

  # Clear hosts.json entries for destroyed resources
  if [ "$do_purge" = true ] && [ -f "hosts.json" ]; then
    doing "Cleaning hosts.json..."
    # Keep only entries that weren't destroyed
    local tmp_hosts
    tmp_hosts=$(mktemp)
    jq '{
      external: [.external[] | select(.hostname | test("^(dns-|nomad|docker|kasm|step-ca)") | not)],
      internal: [.internal[] | select(.hostname | test("^(labnet-dns-)") | not)]
    }' hosts.json > "$tmp_hosts" 2>/dev/null && mv "$tmp_hosts" hosts.json || rm -f "$tmp_hosts"
  fi

  # Report what was purged
  local purged_count=0
  [ "$do_purge" = true ] && purged_count=$total_found
  [ "$do_purge_templates" = true ] && purged_count=$((purged_count + ${#FOUND_TEMPLATES[@]}))

  if [ $purged_count -gt 0 ]; then
    success "Purged $purged_count resource(s) from cluster"
    [ "$do_purge_templates" = true ] && info "  (including Packer templates)"
  fi
  echo
}