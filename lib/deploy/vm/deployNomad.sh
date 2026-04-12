#!/usr/bin/env bash

# deployNomadOnly - Build Nomad template and deploy 3-node Nomad cluster
#
# Prerequisites:
#   - Critical services deployed (DNS, CA)
#   - cluster-info.json with network configuration
#   - Shared storage configured for multi-node clusters
#
# Globals read: DNS_POSTFIX, KEY_PATH, PROXMOX_HOST, VM_USER, GLUSTER_BRICK, GLUSTER_VOLUME
# Globals modified: DEPLOY_PHASE
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Builds Nomad Packer template (VMID 9002)
#   - Deploys Nomad VMs (VMID 905-907)
#   - Configures GlusterFS replicated volume
#   - Updates hosts.json with VM IPs
function deployNomadOnly() {
  cat <<EOF

############################################################################
Nomad Cluster Deployment

This will build the Nomad Packer template and deploy Nomad VMs.
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

  # ============================================
  # Build Nomad Packer Template Only
  # ============================================
  cat <<EOF

#############################################################################
Building Nomad Template

Building only the Nomad VM template with Packer.
#############################################################################
EOF
  pressAnyKey

  # Remove existing template if present
  removeTemplateIfExists 9002 "nomad-template"

  # (packer.auto.pkrvars.hcl storage settings already written by bootstrap)
  doing "Building Nomad Packer template..."
  docker compose build packer >/dev/null 2>&1
  docker compose run --rm -it packer init .
  if ! docker compose run --rm -it packer build -only=ubuntu-nomad.proxmox-clone.ubuntu-nomad .; then
    error "Packer build failed for Nomad template"
    return 1
  fi
  success "Nomad template built"

  # Migrate template disk to shared storage for multi-node cloning
  migrateTemplateToSharedStorage 9002

  # ============================================
  # Deploy Nomad VMs
  # ============================================
  cat <<EOF

#############################################################################
Deploying Nomad VMs

Deploying Nomad cluster VMs from template.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying Nomad VMs..."
  docker compose run --rm -it terraform init
  if ! docker compose run --rm -it terraform apply -target=module.nomad; then
    error "Terraform apply failed for Nomad module"
    return 1
  fi

  success "Nomad VMs deployed"

  # Terraform outputs often have stale IPs for DHCP VMs
  # Query Proxmox directly via QEMU guest agent for actual IPs
  refreshHostsJsonFromProxmox "nomad" 905 907

  # Update DNS records with actual IPs
  updateDNSRecords

  # GlusterFS + Nomad cluster formation is handled by Terraform provisioners
  # in terraform/vm-nomad/main.tf (remote-exec after VM creation)

  displayDeploymentSummary

  success "Nomad cluster deployment complete!"
}

# ensureNomadCluster - Verify Nomad cluster is deployed and healthy
#
# Checks that at least one Nomad node is responding to API requests.
# Used as a prerequisite check before deploying Nomad jobs.
#
# Prerequisites:
#   - hosts.json must exist with nomad entries
#
# Globals read: KEY_PATH
# Arguments: None
# Returns: 0 if cluster healthy, 1 if not deployed or unhealthy
function ensureNomadCluster() {
  if [ ! -f "hosts.json" ]; then
    error "hosts.json not found. Deploy infrastructure first."
    return 1
  fi

  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  if [ -z "$NOMAD_IP" ] || [ "$NOMAD_IP" = "null" ]; then
    error "No Nomad nodes found in hosts.json. Deploy Nomad first (option 5)."
    return 1
  fi

  doing "Verifying Nomad cluster health..."

  # Check if Nomad API is responding
  local NOMAD_STATUS
  NOMAD_STATUS=$(curl -s --connect-timeout 5 "http://$NOMAD_IP:4646/v1/agent/health" 2>/dev/null || echo "")

  if [ -z "$NOMAD_STATUS" ]; then
    error "Cannot reach Nomad API at http://$NOMAD_IP:4646"
    error "Ensure Nomad cluster is running before deploying Nomad jobs."
    return 1
  fi

  success "Nomad cluster is healthy at $NOMAD_IP"
  return 0
}