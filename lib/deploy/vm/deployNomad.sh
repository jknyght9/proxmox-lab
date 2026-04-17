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

  # Update Packer config with storage settings
  updatePackerStorageConfig

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

  # ============================================
  # Configure Nomad Cluster
  # ============================================
  cat <<EOF

#############################################################################
Configuring Nomad Cluster

Setting up GlusterFS and verifying Nomad cluster formation.
#############################################################################
EOF
  pressAnyKey

  setupNomadCluster

  displayDeploymentSummary

  success "Nomad cluster deployment complete!"
}

function setupNomadCluster() {
  local BRICK="$GLUSTER_BRICK/$GLUSTER_VOLUME"
  local VOL="$GLUSTER_VOLUME"
  local MOUNTPOINT="$NOMAD_DATA_DIR"

  doing "Setting up Nomad cluster"
  NODE_IPS=()
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && NODE_IPS+=("$ip")
  done < <(
    jq -r '.external[] | select(.hostname | contains("nomad")) | .ip' hosts.json \
    | sed 's:/.*$::'
  )

  if ((${#NODE_IPS[@]} < 1)); then
    echo "No Nomad hosts found to configure."
    return 1
  fi

  if ((${#NODE_IPS[@]} < 3)); then
    warn "Expected 3 Nomad nodes, found ${#NODE_IPS[@]}. Some operations may fail."
  fi

  MGR="${NODE_IPS[0]}"
  ND1="${NODE_IPS[1]:-$MGR}"
  ND2="${NODE_IPS[2]:-$MGR}"

  # Verify connectivity to all nodes first
  doing "Verifying SSH connectivity to Nomad nodes..."
  for ip in "${NODE_IPS[@]}"; do
    if ! sshRunAdmin "$VM_USER" "$ip" "hostname" &>/dev/null; then
      error "Cannot connect to $ip as $VM_USER"
      return 1
    fi
    info "  Connected to $ip"
  done

  # Create brick directories on all nodes first
  doing "Creating brick directories on all nodes..."
  for ip in "${NODE_IPS[@]}"; do
    sshRunAdmin "$VM_USER" "$ip" "sudo mkdir -p $BRICK && sudo mkdir -p $MOUNTPOINT"
  done

  # Probe peers for GlusterFS
  for peer in "${NODE_IPS[@]}"; do
    if ! sshRunAdmin "$VM_USER" "$MGR" "sudo gluster pool list | awk '{print \$2}' | grep -qx '$peer'"; then
      doing "Probing peer $peer"
      sshRunAdmin "$VM_USER" "$MGR" "sudo gluster peer probe $peer"
    else
      info "$peer is already in pool"
    fi
  done

  sleep 2

  # Create and start GlusterFS volume
  BRICKS="$MGR:$BRICK $ND1:$BRICK $ND2:$BRICK"
  if ! sshRunAdmin "$VM_USER" "$MGR" "sudo gluster volume info $VOL >/dev/null 2>&1"; then
    doing "Creating volume $VOL"
    sshRunAdmin "$VM_USER" "$MGR" "sudo gluster volume create $VOL replica 3 $BRICKS force"
  else
    info "Volume $VOL exists"
  fi

  if ! sshRunAdmin "$VM_USER" "$MGR" "sudo gluster volume status $VOL >/dev/null 2>&1"; then
    doing "Starting volume $VOL"
    sshRunAdmin "$VM_USER" "$MGR" "sudo gluster volume start $VOL"
  fi

  sleep 2

  # Set recommended GlusterFS options
  for opt in \
    "cluster.quorum-type auto" \
    "cluster.self-heal-daemon on" \
    "cluster.data-self-heal on" \
    "cluster.metadata-self-heal on" \
    "cluster.entry-self-heal on" \
    "performance.client-io-threads on" \
    "network.ping-timeout 10"
  do
    sshRunAdmin "$VM_USER" "$MGR" "sudo gluster volume set $VOL $opt || true"
  done

  sleep 2

  # Mount with fstab on all nodes.
  #
  # The fstab options sequence the mount against glusterd and make it safe
  # across boots:
  #   _netdev                           - defer to remote-fs.target
  #   nofail                            - don't block boot if unavailable
  #   x-systemd.requires=glusterd.service
  #   x-systemd.after=glusterd.service
  #
  # The matching RequiresMountsFor=/srv/gluster/nomad-data drop-ins baked
  # into the Packer image for docker.service and nomad.service ensure those
  # services only start once this mount is up — so no Nomad job can bind
  # an empty pre-mount local directory on reboot.
  local FSTAB_LINE="localhost:/${VOL} ${MOUNTPOINT} glusterfs defaults,_netdev,nofail,x-systemd.requires=glusterd.service,x-systemd.after=glusterd.service 0 0"
  for ip in "${NODE_IPS[@]}"; do
    doing "Mounting GlusterFS on $ip"
    sshRunAdmin "$VM_USER" "$ip" "sudo mkdir -p '$MOUNTPOINT'"
    # Replace any existing gluster fstab line with the new form (idempotent).
    sshRunAdmin "$VM_USER" "$ip" "sudo sed -i '\|^localhost:/${VOL}[[:space:]]|d' /etc/fstab && echo '$FSTAB_LINE' | sudo tee -a /etc/fstab >/dev/null"
    sshRunAdmin "$VM_USER" "$ip" "sudo systemctl daemon-reload"
    # Mount if not already mounted
    sshRunAdmin "$VM_USER" "$ip" "mountpoint -q '$MOUNTPOINT' || sudo mount -t glusterfs localhost:/${VOL} ${MOUNTPOINT}"
  done

  # Write the mount sentinel through one node — gluster replicates it to all.
  # Per-job prestart guards read this marker to confirm the volume is really
  # mounted (not a pre-mount empty local directory).
  sshRunAdmin "$VM_USER" "$MGR" "printf 'v1\\n' | sudo tee '$MOUNTPOINT/.mount-sentinel' >/dev/null && sudo chmod 644 '$MOUNTPOINT/.mount-sentinel'"

  sleep 2

  # Restart Nomad now that GlusterFS is mounted
  doing "Starting Nomad on all nodes..."
  for ip in "${NODE_IPS[@]}"; do
    sshRunAdmin "$VM_USER" "$ip" "sudo systemctl restart nomad"
  done

  sleep 2

  # Verify GlusterFS
  sshRunAdmin "$VM_USER" "$MGR" "sudo gluster volume info $VOL"
  sshRunAdmin "$VM_USER" "$MGR" "sudo gluster volume status $VOL"
  sshRunAdmin "$VM_USER" "$MGR" "sudo gluster volume heal $VOL info || true"

  success "GlusterFS '$VOL' up on: ${NODE_IPS[*]}"
  info "Mounted at ${MOUNTPOINT} on each node."

  # Wait for Nomad cluster to form (servers auto-join via cloud-init config)
  doing "Waiting for Nomad cluster to form..."
  sleep 10

  local retries=30
  local count=0
  while [ $count -lt $retries ]; do
    SERVER_COUNT=$(sshRunAdmin "$VM_USER" "$MGR" "nomad server members 2>/dev/null | grep -c alive || echo 0")
    if [ "$SERVER_COUNT" -eq 3 ]; then
      success "Nomad cluster formed with 3 server members"
      break
    fi
    ((count++))
    info "Waiting for Nomad servers to join... ($count/$retries) - $SERVER_COUNT/3 servers alive"
    sleep 5
  done

  if [ $count -eq $retries ]; then
    warn "Nomad cluster may not be fully formed. Please check manually."
  fi

  # Verify Nomad cluster health
  doing "Verifying Nomad cluster health"
  sshRunAdmin "$VM_USER" "$MGR" "nomad server members"
  sshRunAdmin "$VM_USER" "$MGR" "nomad node status"

  success "Nomad cluster setup complete!"
  info "Access Nomad UI at: http://${MGR}:4646"
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