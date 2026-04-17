#!/usr/bin/env bash

# deployAllServices - Full deployment of all lab services
#
# Deploys in phases:
#   Phase 1: Packer templates (base cloud images + docker/nomad templates)
#   Phase 2: Nomad VMs (static IPs, cloud-init sets Pi-hole DNS)
#   Phase 3: Vault (deploy + PKI + sync secrets + vault.auto.tfvars)
#   Phase 4: DNS + Kasm (full terraform apply — Vault passwords now available)
#   Phase 5: Traefik, DNS records, summary
#
# Note: Nomad VMs are provisioned with Pi-hole DNS in cloud-init, but Pi-hole
# isn't deployed until Phase 4. Between Phases 2-4, we temporarily switch
# Nomad VMs to use the network gateway for DNS so Docker pulls work in Phase 3.
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

# switchNomadDNS - Temporarily switch DNS on all Nomad VMs
#
# Nomad VMs are created with Pi-hole DNS (dns_primary_ipv4) in cloud-init,
# but Pi-hole isn't available until Phase 4. This function switches DNS to
# the gateway for Phases 2-3 (so Docker pulls work) and back to Pi-hole
# after Phase 4.
#
# Arguments: $1 - DNS server IP to set (gateway or Pi-hole)
# Returns: 0 on success
function switchNomadDNS() {
  local DNS_SERVER="$1"
  local NOMAD_IPS

  # Get Nomad IPs from hosts.json or terraform.tfvars
  if [ -f "hosts.json" ]; then
    NOMAD_IPS=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  fi

  # Fallback: read from cluster-info.json vm_configs
  if [ -z "$NOMAD_IPS" ]; then
    NOMAD_IPS=$(grep -oP '(?<=ip = ")[^"]+' terraform/vm-nomad/variables.tf 2>/dev/null || true)
  fi

  if [ -z "$NOMAD_IPS" ]; then
    warn "Could not determine Nomad VM IPs — skipping DNS switch"
    return 0
  fi

  doing "Switching Nomad VM DNS to $DNS_SERVER..."
  for ip in $NOMAD_IPS; do
    sshRunAdmin "$VM_USER" "$ip" "sudo resolvectl dns eth0 $DNS_SERVER" 2>/dev/null || true
  done
  success "Nomad VMs now using DNS: $DNS_SERVER"
}
function deployAllServices() {
  cat <<EOF

############################################################################
Full Services Deployment

Phase 1: Build Packer templates (base images + Docker/Nomad)
Phase 2: Deploy Nomad cluster (3-node, static IPs)
Phase 3: Deploy Vault (secrets + PKI + sync credentials)
Phase 4: Deploy DNS + Kasm (with Vault-managed passwords)
Phase 5: Deploy Traefik, configure DNS records
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

  if [ -z "$DNS_POSTFIX" ]; then
    read -rp "$(question "Enter DNS domain suffix (e.g., lab.local): ")" DNS_POSTFIX
    while [ -z "$DNS_POSTFIX" ]; do
      warn "DNS domain suffix is required"
      read -rp "$(question "DNS domain suffix: ")" DNS_POSTFIX
    done
  fi

  # Load pre-generated service passwords
  if ! loadServicePasswords; then
    error "Service passwords not generated. Run setup.sh first."
    return 1
  fi
  PIHOLE_PASSWORD="$PIHOLE_ADMIN_PASSWORD"

  # Load cluster info if not already loaded
  if [ ${#CLUSTER_NODES[@]} -eq 0 ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      loadClusterInfo
    else
      detectClusterNodes
    fi
  fi

  # ============================================
  # PHASE 1: Build Packer Templates
  # ============================================

  # Check if templates already exist
  local TEMPLATES_EXIST=false
  if sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_DOCKER_TEMPLATE" &>/dev/null && \
     sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_NOMAD_TEMPLATE" &>/dev/null; then
    TEMPLATES_EXIST=true
  fi

  if [ "$TEMPLATES_EXIST" = "true" ]; then
    info "Skipping Packer build — templates already exist (9001, 9002)"
    DEPLOY_PHASE=1
  else
    cat <<EOF

#############################################################################
Phase 1: Template Creation

Building VM templates with Packer (base cloud images + Docker/Nomad).
#############################################################################
EOF
    pressAnyKey

    doing "Preparing Packer..."
    docker compose build packer >/dev/null 2>&1
    docker compose run --rm -it packer init .

    # Step 1: Build base cloud image templates (9997-9999)
    if ! sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_BASE_TEMPLATE" &>/dev/null; then
      doing "Building base VM templates (cloud images + guest agent)..."
      if ! docker compose run --rm -it packer build -only='base-*.*' .; then
        error "Base template build failed"
        return 1
      fi
      success "Base templates built"
    else
      info "Base template $VMID_BASE_TEMPLATE already exists — skipping"
    fi

    # Step 2: Build docker + nomad templates (clone from base)
    removeTemplateIfExists 9001 "docker-template"
    removeTemplateIfExists 9002 "nomad-template"

    doing "Building Docker and Nomad templates..."
    if ! docker compose run --rm -it packer build \
        -only='ubuntu-docker.*' -only='ubuntu-nomad.*' .; then
      error "Phase 1 failed: Packer build was not successful"
      DEPLOY_PHASE=1
      read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
      DO_ROLLBACK=${DO_ROLLBACK:-Y}
      if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
        rollbackDeployment 1
      fi
      return 1
    fi

    DEPLOY_PHASE=1
    success "Phase 1 complete: Packer templates built"

    # Templates stay on shared storage (nfs-syno-templates) so all nodes
    # can clone from them. Terraform handles disk placement to vm_storage
    # at deploy time via disk.datastore_id.
  fi

  # ============================================
  # PHASE 2: Deploy Nomad VMs (static IPs, no DNS needed)
  # ============================================

  # Check if Nomad VMs already exist
  local NOMAD_ALREADY_DEPLOYED=false
  if [ -f "hosts.json" ]; then
    local NOMAD_IP
    NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
    if [ -n "$NOMAD_IP" ] && [ "$NOMAD_IP" != "null" ]; then
      if sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm status $VMID_NOMAD_START" &>/dev/null; then
        NOMAD_ALREADY_DEPLOYED=true
        success "Nomad VMs already deployed — skipping Phase 2"
      fi
    fi
  fi

  if [ "$NOMAD_ALREADY_DEPLOYED" = "false" ]; then
    cat <<EOF

#############################################################################
Phase 2: Nomad Cluster Deployment

Deploying 3-node Nomad cluster with GlusterFS shared storage.
Using gateway DNS for provisioning (Pi-hole not required yet).
#############################################################################
EOF
    pressAnyKey

    doing "Deploying Nomad VMs..."
    docker compose build terraform >/dev/null 2>&1
    docker compose run --rm -it terraform init

    if ! docker compose run --rm -it terraform apply \
      -parallelism=1 \
      -target=module.nomad; then
      error "Phase 2 failed: Nomad VM deployment"
      DEPLOY_PHASE=2
      read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
      DO_ROLLBACK=${DO_ROLLBACK:-Y}
      if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
        rollbackDeployment 2
      fi
      return 1
    fi

    DEPLOY_PHASE=2
    success "Phase 2 complete: Nomad cluster deployed"

    # Get actual Nomad VM IPs from QEMU guest agent
    refreshHostsJsonFromProxmox "nomad" $VMID_NOMAD_START $VMID_NOMAD_END
  fi

  # Nomad VMs were created with Pi-hole DNS (not yet deployed).
  # Switch to gateway DNS so Docker pulls work during Phase 3.
  local GATEWAY_IP
  GATEWAY_IP=$(jq -r '.network.external.gateway // empty' "$CLUSTER_INFO_FILE" 2>/dev/null)
  if [ -n "$GATEWAY_IP" ]; then
    switchNomadDNS "$GATEWAY_IP"
  fi

  # ============================================
  # PHASE 3: Deploy Vault + sync secrets
  # ============================================
  cat <<EOF

#############################################################################
Phase 3: Vault Deployment

Deploying HashiCorp Vault on Nomad, initializing PKI, and syncing
service passwords. This enables Vault-managed secrets for DNS and Kasm.
#############################################################################
EOF
  pressAnyKey

  # Deploy Vault with PKI (writes vault.auto.tfvars on success)
  if ! deployVaultWithCA; then
    error "Phase 3 failed: Vault deployment"
    DEPLOY_PHASE=3
    return 1
  fi

  # Sync local service passwords to Vault KV
  doing "Syncing service passwords to Vault..."
  if ! syncSecretsToVault; then
    error "Failed to sync secrets to Vault"
    return 1
  fi
  success "Secrets synced to Vault"

  DEPLOY_PHASE=3
  success "Phase 3 complete: Vault operational, secrets synced"

  # ============================================
  # PHASE 4: Deploy DNS + Kasm (Vault passwords available)
  # ============================================

  # Verify all nodes can reach the internet (needed for DNS provisioning)
  if ! checkClusterConnectivity; then
    error "Cannot proceed without internet connectivity on all nodes."
    return 1
  fi

  # Download LXC templates (Debian for Pi-hole containers)
  if ! downloadLXCTemplates; then
    error "Cannot proceed without LXC templates."
    return 1
  fi

  cat <<EOF

#############################################################################
Phase 4: DNS + Kasm Deployment

Deploying Pi-hole DNS cluster and Kasm Workspaces.
Passwords are now managed by Vault.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying DNS and Kasm..."

  # Full terraform apply — Vault is now available, so data sources will
  # read passwords from Vault KV instead of using "vault-not-configured"
  if ! docker compose run --rm -it terraform apply; then
    error "Phase 4 failed: DNS/Kasm deployment"
    DEPLOY_PHASE=4
    read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
    DO_ROLLBACK=${DO_ROLLBACK:-Y}
    if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
      rollbackDeployment 4
    fi
    return 1
  fi

  DEPLOY_PHASE=4
  success "Phase 4 complete: DNS and Kasm deployed"

  # Pi-hole is now running — switch Nomad VMs back to Pi-hole DNS
  local DNS_PRIMARY_IP
  DNS_PRIMARY_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
  if [ -n "$DNS_PRIMARY_IP" ] && [ "$DNS_PRIMARY_IP" != "null" ]; then
    switchNomadDNS "$DNS_PRIMARY_IP"
  fi

  # Refresh hosts.json with actual IPs
  doing "Refreshing Terraform state..."
  docker compose run --rm -T terraform refresh >/dev/null 2>&1 || true

  doing "Generating hosts.json from Terraform outputs..."
  if docker compose run --rm -T terraform output -json host-records 2>/dev/null > hosts.json; then
    if jq -e '.external' hosts.json >/dev/null 2>&1; then
      success "hosts.json generated"
    else
      warn "hosts.json invalid, recreating from module outputs..."
      generateHostsJsonFromModules
    fi
  else
    warn "Could not generate hosts.json, using module outputs..."
    generateHostsJsonFromModules
  fi

  # Refresh Kasm IPs (optional — may not be deployed)
  refreshHostsJsonFromProxmox "kasm" $VMID_KASM $VMID_KASM || true

  # ============================================
  # PHASE 5: Traefik + DNS records
  # ============================================

  # Deploy Traefik reverse proxy
  if ! deployTraefikOnly; then
    error "Phase 5 failed: Traefik deployment"
    DEPLOY_PHASE=5
    return 1
  fi

  DEPLOY_PHASE=5

  displayDeploymentSummary

  success "Deployment complete!"
}
