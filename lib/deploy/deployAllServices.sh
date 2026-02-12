#!/usr/bin/env bash

# deployAllServices - Full deployment of all lab services
#
# Deploys in phases:
#   Phase 1: LXC containers (DNS, step-ca)
#   Phase 2: Packer templates (docker, nomad)
#   Phase 3: VMs (Nomad cluster, Kasm)
#
# Prerequisites:
#   - cluster-info.json with network configuration
#   - Internet connectivity on all Proxmox nodes
#   - LXC templates available on all nodes
#
# Globals read: DNS_POSTFIX, KEY_PATH, PROXMOX_HOST, CLUSTER_NODE_IPS
# Globals modified: DEPLOY_PHASE
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates LXC containers, VM templates, and VMs
#   - Updates hosts.json with deployed IPs
#   - Configures DNS records and root certificates
function deployAllServices() {
  cat <<EOF

############################################################################
Full Services Deployment

Deploying all services: Pi-hole DNS with Unbound (DNS-over-TLS),
Certificate Authority (Step-CA), Nomad cluster, and Kasm Workspaces.
#############################################################################

EOF

  # Check for and purge existing resources before deployment
  if ! purgeClusterResources; then
    read -rp "$(question "Continue deployment anyway? Resources may conflict. [y/N]: ")" confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && warn "Deployment cancelled" && return 1
  fi

  # Load configuration from cluster-info.json if not already loaded
  if [ -z "$DNS_POSTFIX" ] && [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
  fi

  # If still no DNS_POSTFIX, prompt for it
  if [ -z "$DNS_POSTFIX" ]; then
    read -rp "$(question "Enter DNS domain suffix (e.g., lab.local): ")" DNS_POSTFIX
    while [ -z "$DNS_POSTFIX" ]; do
      warn "DNS domain suffix is required"
      read -rp "$(question "DNS domain suffix: ")" DNS_POSTFIX
    done
  fi

  # Check if DNS and CA are actually deployed (verify containers exist on Proxmox)
  local DNS_ALREADY_DEPLOYED=false
  if [ -f "hosts.json" ]; then
    local DNS_IP
    DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
    if [ -n "$DNS_IP" ] && [ "$DNS_IP" != "null" ]; then
      # Verify the LXC container actually exists on Proxmox (VMID 910 = dns-01, 902 = step-ca)
      doing "Verifying DNS and CA containers exist on Proxmox..."
      local dns_exists=false
      local ca_exists=false

      # Check across all cluster nodes for the containers
      for node_ip in "${CLUSTER_NODE_IPS[@]}"; do
        if sshRun "$REMOTE_USER" "$node_ip" "pct status $VMID_DNS_START" &>/dev/null; then
          dns_exists=true
        fi
        if sshRun "$REMOTE_USER" "$node_ip" "pct status $VMID_STEP_CA" &>/dev/null; then
          ca_exists=true
        fi
      done

      if [ "$dns_exists" = "true" ] && [ "$ca_exists" = "true" ]; then
        DNS_ALREADY_DEPLOYED=true
        success "DNS ($DNS_IP) and CA containers verified on Proxmox"
      else
        warn "hosts.json has DNS/CA entries but containers not found on Proxmox"
        warn "Will redeploy LXC containers..."
        # Clean stale hosts.json entries
        rm -f hosts.json
      fi
    fi
  fi

  # Only prompt for Pi-hole password if DNS is not already deployed
  if [ "$DNS_ALREADY_DEPLOYED" = "false" ]; then
    while true; do
      read -rsp "$(question "Enter Pi-hole admin password: ")" PIHOLE_PASSWORD
      echo ""
      if [ -z "$PIHOLE_PASSWORD" ]; then
        warn "Password cannot be empty"
        continue
      fi
      read -rsp "$(question "Confirm Pi-hole admin password: ")" PIHOLE_PASSWORD_CONFIRM
      echo ""
      if [ "$PIHOLE_PASSWORD" != "$PIHOLE_PASSWORD_CONFIRM" ]; then
        warn "Passwords do not match"
        continue
      fi
      break
    done

    # Display configuration summary
    cat <<EOF

======================================
Deployment Configuration:
--------------------------------------
DNS suffix:               $DNS_POSTFIX
Pi-hole admin pass:       $PIHOLE_PASSWORD
======================================

EOF

    read -rp "$(question "Proceed with deployment? [Y/n]: ")" CONFIRM
    CONFIRM=${CONFIRM:-Y}
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && warn "Deployment cancelled" && return 1
  else
    # DNS exists, use existing password from terraform.tfvars
    if [ -f "terraform/terraform.tfvars" ]; then
      PIHOLE_PASSWORD=$(grep "^pihole_admin_password" terraform/terraform.tfvars | cut -d'"' -f2)
    fi
    info "Using existing DNS deployment, skipping password prompt"
  fi

  # Load cluster info if not already loaded
  if [ ${#CLUSTER_NODES[@]} -eq 0 ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      loadClusterInfo
    else
      detectClusterNodes
    fi
  fi

  # Skip LXC deployment if DNS and CA already exist
  if [ "$DNS_ALREADY_DEPLOYED" = "true" ]; then
    info "Skipping LXC deployment - DNS and CA already deployed"
    info "Proceeding directly to Packer/VM phases..."
    DEPLOY_PHASE=1
  else
    # Update the step-ca installation script with DNS postfix
    if sed --version >/dev/null 2>&1; then
        sed -i "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
    else
        sed -i '' "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
    fi
    success "Step-CA installation script updated"

    # Generate certificates
    generateCertificates

    # Verify all nodes can reach the internet before proceeding
    if ! checkClusterConnectivity; then
      error "Cannot proceed without internet connectivity on all nodes."
      return 1
    fi

    # Ensure LXC templates are available on all nodes
    if ! ensureLXCTemplates; then
      error "Cannot proceed without LXC templates on all nodes."
      return 1
    fi

    # ============================================
    # PHASE 1: Deploy LXC Containers (DNS, step-ca)
    # ============================================
    cat <<EOF

#############################################################################
LXC Container Deployment

Deploying critical infrastructure: DNS servers and Certificate Authority.
These must be operational before building VM templates.
#############################################################################
EOF
    pressAnyKey

    doing "Deploying LXC containers (DNS, step-ca)..."
    docker compose build terraform >/dev/null 2>&1
    docker compose run --rm -it terraform init

    if ! docker compose run --rm -it terraform apply \
      -target=module.dns-main \
      -target=module.dns-labnet \
      -target=module.step-ca; then
      error "Phase 1 failed: LXC container deployment"
      DEPLOY_PHASE=1
      read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
      DO_ROLLBACK=${DO_ROLLBACK:-Y}
      if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
        rollbackDeployment 1
      fi
      return 1
    fi

    DEPLOY_PHASE=1
    success "Phase 1 complete: LXC containers deployed"

    # Refresh terraform state to update outputs after targeted apply
    doing "Refreshing Terraform state to update outputs..."
    docker compose run --rm -T terraform refresh -target=module.dns-main -target=module.dns-labnet -target=module.step-ca >/dev/null 2>&1 || true

    # Generate hosts.json from terraform output (may be partial during Phase 1)
    doing "Generating hosts.json from Terraform outputs..."
    if docker compose run --rm -T terraform output -json host-records > hosts.json 2>&1; then
      # Check if the output is valid JSON (not an error message)
      if jq -e '.external' hosts.json >/dev/null 2>&1; then
        success "hosts.json generated successfully"
      else
        warn "hosts.json contains invalid data, recreating from individual outputs..."
        generateHostsJsonFromModules
      fi
    else
      warn "Could not generate hosts.json from terraform output, using individual module outputs..."
      generateHostsJsonFromModules
    fi

    updateDNSRecords
    updateRootCertificates
  fi  # End of DNS_ALREADY_DEPLOYED=false block

  # Storage selection for multi-node clusters
  ensureSharedStorage || return 1
  updatePackerStorageConfig

  # Check if templates already exist
  local TEMPLATES_EXIST=false
  if sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_DOCKER_TEMPLATE" &>/dev/null && \
     sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_NOMAD_TEMPLATE" &>/dev/null; then
    TEMPLATES_EXIST=true
  fi

  # ============================================
  # PHASE 2: Build Packer Templates
  # ============================================
  if [ "$TEMPLATES_EXIST" = "true" ] && [ "$DNS_ALREADY_DEPLOYED" = "true" ]; then
    info "Skipping Packer build - templates already exist (9001, 9002)"
    DEPLOY_PHASE=2
  else
    cat <<EOF

#############################################################################
Template Creation

Building VM templates with Packer. DNS and CA are now available.
#############################################################################
EOF
    pressAnyKey

    # Check for existing templates and remove them
    removeTemplateIfExists 9001 "docker-template"
    removeTemplateIfExists 9002 "nomad-template"

    doing "Building Packer templates..."
    docker compose build packer >/dev/null 2>&1
    docker compose run --rm -it packer init .
    if ! docker compose run --rm -it packer build .; then
      error "Phase 2 failed: Packer build was not successful"
      DEPLOY_PHASE=2
      read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
      DO_ROLLBACK=${DO_ROLLBACK:-Y}
      if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
        rollbackDeployment 2
      fi
      return 1
    fi

    DEPLOY_PHASE=2
    success "Phase 2 complete: Packer templates built"

    # Migrate template disks to shared storage for multi-node cloning
    migrateTemplateToSharedStorage 9001
    migrateTemplateToSharedStorage 9002
  fi  # End of TEMPLATES_EXIST=false block

  # ============================================
  # PHASE 3: Deploy VMs (nomad, kasm)
  # ============================================
  cat <<EOF

#############################################################################
VM Deployment

Deploying Nomad cluster and Kasm VMs from templates.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying VMs..."
  if ! docker compose run --rm -it terraform apply; then
    error "Phase 3 failed: VM deployment"
    DEPLOY_PHASE=3
    read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
    DO_ROLLBACK=${DO_ROLLBACK:-Y}
    if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
      rollbackDeployment 3
    fi
    return 1
  fi

  DEPLOY_PHASE=3
  success "Phase 3 complete: VMs deployed"

  # Terraform outputs often have stale IPs for DHCP VMs
  # Query Proxmox directly via QEMU guest agent for actual IPs
  refreshHostsJsonFromProxmox "nomad" 905 907
  refreshHostsJsonFromProxmox "kasm" 930 930 || true  # Kasm is optional, don't fail if not deployed

  # Update DNS records with actual IPs
  updateDNSRecords

  # Configure Nomad cluster (GlusterFS + cluster formation)
  setupNomadCluster

  displayDeploymentSummary

  success "Deployment complete!"
}