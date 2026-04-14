#!/usr/bin/env bash

# deployKasmOnly - Deploy Kasm Workspaces VM from docker-template
#
# Prerequisites:
#   - Critical services deployed (DNS, CA)
#   - Docker template (VMID 9001) available or will be built
#   - cluster-info.json with network configuration
#
# Globals read: DNS_POSTFIX, KEY_PATH, PROXMOX_HOST
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Builds docker-template if not present
#   - Deploys Kasm VM (VMID 930)
#   - Updates hosts.json with VM IP
function deployKasmOnly() {
  cat <<EOF

############################################################################
Kasm Workspaces Deployment (Skip LXC)

This will deploy Kasm Workspaces VM from the docker-template.
Assumes DNS and step-ca are already deployed.
#############################################################################

EOF

  # Load cluster context
  ensureClusterContext || return 1

  # Verify critical services are deployed
  ensureCriticalServices || return 1

  # Ensure shared storage is selected for clusters
  ensureSharedStorage || return 1

  # Verify hosts.json exists (needed for DNS records)
  if [ ! -f "hosts.json" ]; then
    warn "hosts.json not found, generating from Terraform..."
    docker compose run --rm -T terraform output -json host-records > hosts.json 2>&1 || true
  fi

  # Check if docker-template exists, offer to build if missing
  if ! ensureTemplate 9001 "docker-template"; then
    echo
    warn "docker-template (VM 9001) is required but not found."
    read -rp "$(question "Build docker-template now? [Y/n]: ")" BUILD_TEMPLATE
    if [[ "$BUILD_TEMPLATE" =~ ^[Nn]$ ]]; then
      info "Cannot deploy Kasm without docker-template."
      return 1
    fi

    # Build docker template only
    # (Storage/API config already written to packer.auto.pkrvars.hcl by bootstrap)
    doing "Building docker-template with Packer..."
    docker compose build packer >/dev/null 2>&1
    docker compose run --rm -it packer init .
    if ! docker compose run --rm -it packer build -only=ubuntu-docker.proxmox-clone.ubuntu-docker .; then
      error "Packer build failed for docker-template"
      return 1
    fi
    success "docker-template built"

  fi

  # ============================================
  # Deploy Kasm VM
  # ============================================
  cat <<EOF

#############################################################################
Deploying Kasm Workspaces

Deploying Kasm VM from docker-template.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying Kasm VM..."
  docker compose run --rm -it terraform init
  if ! docker compose run --rm -it terraform apply -target=module.kasm; then
    error "Terraform apply failed for Kasm module"
    return 1
  fi

  success "Kasm VM deployed"

  # Terraform outputs often have stale IPs for DHCP VMs
  # Query Proxmox directly via QEMU guest agent for actual IPs
  refreshHostsJsonFromProxmox "kasm" 930 930

  # Update DNS records with actual IPs
  updateDNSRecords

  displayDeploymentSummary

  success "Kasm deployment complete!"
}