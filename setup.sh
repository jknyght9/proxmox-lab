#!/usr/bin/env bash
#
# Proxmox Lab — Interactive setup menu
#
# Two-layer Terraform architecture:
#   Layer 1 (terraform/)          — Infrastructure: VMs, LXCs, GlusterFS, Vault job
#   Layer 2 (terraform/services/) — Services: Vault config, Nomad jobs, secrets, PKI
#
# Usage:
#   ./setup.sh               # interactive menu
#   ./setup.sh --dev         # includes developer tools

set -euo pipefail
export TERM=xterm

# Resolve project directory (script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# Library sourcing (only what's still needed)
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/bootstrap.sh"
source "$SCRIPT_DIR/lib/credentials.sh"

source "$SCRIPT_DIR/lib/proxmox/clusterHelpers.sh"
source "$SCRIPT_DIR/lib/proxmox/configureProxmox.sh"
source "$SCRIPT_DIR/lib/proxmox/purgeClusterResources.sh"
source "$SCRIPT_DIR/lib/proxmox/selectSharedStorage.sh"
source "$SCRIPT_DIR/lib/proxmox/ssh.sh"
source "$SCRIPT_DIR/lib/proxmox/templateHelpers.sh"

source "$SCRIPT_DIR/lib/packerHelpers.sh"
source "$SCRIPT_DIR/lib/deploy/purgeDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackManual.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/initVault.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/unsealVault.sh"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
DEV_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--dev" ]] && DEV_MODE=true
done

# -----------------------------------------------------------------------------
# Global state
# -----------------------------------------------------------------------------
CRYPTO_DIR="$SCRIPT_DIR/crypto"
ENTERPRISE_KEY_NAME="labenterpriseadmin"
ENTERPRISE_KEY_PATH="$CRYPTO_DIR/$ENTERPRISE_KEY_NAME"
ENTERPRISE_PUBKEY_PATH="$ENTERPRISE_KEY_PATH.pub"
ADMIN_KEY_NAME="labadmin"
ADMIN_KEY_PATH="$CRYPTO_DIR/$ADMIN_KEY_NAME"
ADMIN_PUBKEY_PATH="$ADMIN_KEY_PATH.pub"
REMOTE_USER="root"
CLUSTER_INFO_FILE="$SCRIPT_DIR/cluster-info.json"
VAULT_CREDENTIALS_FILE="$CRYPTO_DIR/vault-credentials.json"

# Cluster globals — populated by discoverCluster / loadClusterInfo
CLUSTER_NODES=()
CLUSTER_NODE_IPS=()
IS_CLUSTER=false
USE_SHARED_STORAGE=false
TEMPLATE_STORAGE=""
NETWORK_BRIDGE=""

# Deployment phase tracking for rollback
DEPLOY_PHASE=0

# -----------------------------------------------------------------------------
# Terraform Helpers
# -----------------------------------------------------------------------------

# Run terraform in Layer 1 (infrastructure)
function tf() {
  docker compose run --rm -it terraform "$@"
}

# Run terraform in Layer 2 (services)
function tf-services() {
  docker compose run --rm -it terraform-services "$@"
}

# Apply a specific Layer 2 service target
function deployService() {
  local target="$1"
  local var_flag="${2:-}"

  ensureBootstrapComplete || return 1

  if [ ! -f "$SCRIPT_DIR/terraform/services/terraform.tfvars" ]; then
    error "Layer 2 not configured. Run 'Deploy all' (option 1) first, or init Vault manually."
    return 1
  fi

  doing "Deploying $target..."
  if [ -n "$var_flag" ]; then
    tf-services apply -auto-approve -var "$var_flag"
  else
    tf-services apply -auto-approve -target="$target"
  fi
}

# Toggle HA — reads settings from bootstrap.yml, writes to terraform.tfvars, applies Layer 1
function toggleHA() {
  ensureBootstrapComplete || return 1

  # Read HA settings from bootstrap.yml
  _bootstrap_init_vars 2>/dev/null || true

  local dns_ha_enabled dns_ha_vip dns_ha_router_id dns_ha_password
  local traefik_ha_enabled traefik_ha_vip traefik_ha_router_id traefik_ha_password

  dns_ha_enabled=$(yamlGet "ha_dns_enabled" 2>/dev/null || echo "false")
  dns_ha_vip=$(yamlGet "ha_dns_vip" 2>/dev/null || echo "")
  dns_ha_router_id=$(yamlGet "ha_dns_vrrp_router_id" 2>/dev/null || echo "51")
  dns_ha_password=$(yamlGet "ha_dns_vrrp_password" 2>/dev/null || echo "pihole-ha")

  traefik_ha_enabled=$(yamlGet "ha_traefik_enabled" 2>/dev/null || echo "false")
  traefik_ha_vip=$(yamlGet "ha_traefik_vip" 2>/dev/null || echo "")
  traefik_ha_router_id=$(yamlGet "ha_traefik_vrrp_router_id" 2>/dev/null || echo "53")
  traefik_ha_password=$(yamlGet "ha_traefik_vrrp_password" 2>/dev/null || echo "traefik-ha")

  if [ "$dns_ha_enabled" != "true" ] && [ "$traefik_ha_enabled" != "true" ]; then
    error "No HA settings found in bootstrap.yml"
    info "Add ha.dns and/or ha.traefik sections to bootstrap.yml first"
    return 1
  fi

  local TFVARS="${SCRIPT_DIR}/terraform/terraform.tfvars"

  echo
  info "HA Configuration from bootstrap.yml:"
  if [ "$dns_ha_enabled" = "true" ]; then
    info "  DNS HA:     VIP=${dns_ha_vip} RouterID=${dns_ha_router_id}"
  else
    info "  DNS HA:     disabled"
  fi
  if [ "$traefik_ha_enabled" = "true" ]; then
    info "  Traefik HA: VIP=${traefik_ha_vip} RouterID=${traefik_ha_router_id}"
  else
    info "  Traefik HA: disabled"
  fi
  echo

  # Remove existing HA lines from tfvars
  sed -i.bak '/^enable_dns_ha_vip/d; /^dns_ha_vip/d; /^dns_ha_vrrp/d; /^nomad_traefik_ha/d' "$TFVARS"
  rm -f "$TFVARS.bak"

  # Write HA settings
  if [ "$dns_ha_enabled" = "true" ] && [ -n "$dns_ha_vip" ]; then
    cat >> "$TFVARS" <<EOF

# DNS HA (keepalived VIP)
enable_dns_ha_vip      = true
dns_ha_vip_address     = "${dns_ha_vip}"
dns_ha_vrrp_router_id  = ${dns_ha_router_id}
dns_ha_vrrp_password   = "${dns_ha_password}"
EOF
  fi

  if [ "$traefik_ha_enabled" = "true" ] && [ -n "$traefik_ha_vip" ]; then
    cat >> "$TFVARS" <<EOF

# Traefik HA (keepalived VIP)
nomad_traefik_ha_enabled        = true
nomad_traefik_ha_vip            = "${traefik_ha_vip}"
nomad_traefik_ha_vrrp_router_id = ${traefik_ha_router_id}
nomad_traefik_ha_vrrp_password  = "${traefik_ha_password}"
EOF
  fi

  success "HA settings written to terraform.tfvars"

  # Get nomad address for apply
  local NOMAD01_IP
  NOMAD01_IP=$(sed -n 's/.*ip = "\([^"]*\)".*/\1/p' terraform/vm-nomad/variables.tf 2>/dev/null | head -1)
  NOMAD01_IP="${NOMAD01_IP:-10.1.50.114}"

  doing "Applying HA configuration..."
  tf apply -auto-approve -var "nomad_address=http://${NOMAD01_IP}:4646"
  success "HA configuration applied"
}

# Enable a service toggle and apply Layer 2
function enableService() {
  local service_name="$1"
  local var_name="deploy_${service_name}"
  local tfvars="$SCRIPT_DIR/terraform/services/terraform.tfvars"

  ensureBootstrapComplete || return 1

  if [ ! -f "$tfvars" ]; then
    error "Layer 2 not configured. Run 'Deploy all' (option 1) first."
    return 1
  fi

  # Add or update the deploy toggle in tfvars
  if grep -q "^${var_name}" "$tfvars"; then
    sed -i.bak "s/^${var_name}.*/${var_name} = true/" "$tfvars"
    rm -f "$tfvars.bak"
  else
    echo "${var_name} = true" >> "$tfvars"
  fi

  doing "Enabling $service_name..."
  tf-services apply -auto-approve
}

# -----------------------------------------------------------------------------
# Main flow: deploy all services
# -----------------------------------------------------------------------------
function deployAll() {
  if [ ! -f "$SCRIPT_DIR/bootstrap.yml" ]; then
    error "bootstrap.yml not found."
    info "Copy bootstrap.yml.example to bootstrap.yml and edit it first."
    return 1
  fi

  checkRequirements
  generateSSHKeys

  # Read bootstrap.yml, discover cluster, create API token,
  # generate terraform.tfvars and packer.auto.pkrvars.hcl.
  runBootstrap || return 1

  # Set PROXMOX_HOST from bootstrap
  PROXMOX_HOST="$PROXMOX_IP"

  # Distribute SSH keys to all discovered nodes
  distributeSSHKeys

  cat <<EOF

############################################################################
Full Services Deployment

Phase 1: Build Packer templates (base + Docker/Nomad)
Phase 2: Deploy Nomad cluster + Vault container
Phase 3: Initialize Vault (init, unseal, save credentials)
Phase 4: Configure services (PKI, secrets, Traefik) + deploy DNS
############################################################################

EOF

  # ============================================
  # PHASE 1: Build Packer Templates
  # ============================================
  local TEMPLATES_EXIST=false
  if sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_DOCKER_TEMPLATE" &>/dev/null && \
     sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_NOMAD_TEMPLATE" &>/dev/null; then
    TEMPLATES_EXIST=true
  fi

  if [ "$TEMPLATES_EXIST" = "true" ]; then
    info "Skipping Packer build — templates already exist (9001, 9002)"
  else
    doing "Phase 1: Building Packer templates..."
    pressAnyKey
    docker compose build packer >/dev/null 2>&1
    docker compose run --rm -it packer init .

    # Build base cloud image if it doesn't exist (required for cloning)
    if ! sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_BASE_TEMPLATE" &>/dev/null; then
      doing "Building base VM template (cloud image + guest agent)..."
      docker compose run --rm -it packer build -only='base-*.*' .
      success "Base template built"
    else
      info "Base template $VMID_BASE_TEMPLATE already exists — skipping"
    fi

    # Build Docker + Nomad templates (clone from base)
    docker compose run --rm -it packer build -only='ubuntu-docker.*' -only='ubuntu-nomad.*' .
    success "Phase 1 complete: Packer templates built"
  fi

  # ============================================
  # PHASE 2: Deploy Infrastructure (Layer 1)
  # ============================================
  cat <<EOF

############################################################################
Phase 2: Infrastructure Deployment

Deploying Nomad cluster, DNS, Kasm, and Vault container via Terraform.
############################################################################

EOF
  pressAnyKey

  # Get first Nomad node IP from vm_configs defaults
  local NOMAD01_IP
  NOMAD01_IP=$(sed -n 's/.*ip = "\([^"]*\)".*/\1/p' terraform/vm-nomad/variables.tf 2>/dev/null | head -1)
  if [ -z "${NOMAD01_IP:-}" ]; then
    NOMAD01_IP="10.1.50.114"
  fi

  doing "Initializing Terraform Layer 1..."
  tf init || { error "Terraform init failed"; return 1; }

  # Deploy Nomad cluster + Vault job only — DNS deploys after Vault
  # has real passwords (avoids placeholder passwords and rebuild)
  doing "Deploying Nomad cluster and Vault (this may take several minutes)..."
  if ! tf apply -auto-approve \
    -var "nomad_address=http://${NOMAD01_IP}:4646" \
    -target=module.nomad \
    -target=nomad_job.vault \
    -target=null_resource.vault_directories; then
    error "Phase 2 failed: Terraform apply"
    return 1
  fi
  success "Phase 2 complete: Nomad cluster and Vault deployed"

  # ============================================
  # PHASE 3: Initialize Vault
  # ============================================
  cat <<EOF

############################################################################
Phase 3: Vault Initialization

Initializing and unsealing Vault. Credentials will be saved to
crypto/vault-credentials.json and Layer 2 tfvars will be generated.
############################################################################

EOF
  pressAnyKey

  # Wait for Vault to be reachable
  doing "Waiting for Vault to be reachable..."
  local vault_ready=false
  for i in {1..30}; do
    if curl -sk --connect-timeout 2 --max-time 3 "http://${NOMAD01_IP}:8200/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1; then
      vault_ready=true
      break
    fi
    sleep 2
  done

  if [ "$vault_ready" != "true" ]; then
    error "Vault not reachable at http://${NOMAD01_IP}:8200 after 60s"
    return 1
  fi

  # Load cluster context for initAndUnsealVault
  loadClusterInfo 2>/dev/null || true
  DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)

  initAndUnsealVault "$NOMAD01_IP"
  success "Phase 3 complete: Vault initialized"

  # ============================================
  # PHASE 4: Configure Services (Layer 2)
  # ============================================
  cat <<EOF

############################################################################
Phase 4: Service Configuration

Configuring Vault PKI, JWT auth, policies, secrets, and deploying
Traefik via Terraform Layer 2. Then deploying DNS and enabling
Vault TLS via Layer 1 (now with real Vault passwords).
############################################################################

EOF
  pressAnyKey

  doing "Initializing Terraform Layer 2..."
  tf-services init

  doing "Running Terraform Layer 2 (PKI, secrets, Traefik)..."
  tf-services apply -auto-approve
  success "Layer 2 complete: Vault configured, Traefik deployed"

  # Full Layer 1 apply: DNS (with real passwords) + Vault TLS redeploy
  # detach=true so terraform doesn't wait for sealed Vault health check
  doing "Deploying DNS and enabling Vault TLS..."
  tf apply -auto-approve -var "nomad_address=http://${NOMAD01_IP}:4646"

  # Vault seals on TLS redeploy — wait for it to come up, then unseal
  doing "Waiting for Vault to restart with TLS..."
  sleep 5
  for i in {1..30}; do
    if curl -sk --connect-timeout 2 "https://${NOMAD01_IP}:8200/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  # Unseal and update address to HTTPS
  local UNSEAL_KEY
  UNSEAL_KEY=$(jq -r '.unseal_key' "$VAULT_CREDENTIALS_FILE")
  doing "Unsealing Vault (TLS)..."
  curl -sk -X PUT "https://${NOMAD01_IP}:8200/v1/sys/unseal" \
    -H "Content-Type: application/json" \
    -d "{\"key\": \"$UNSEAL_KEY\"}" > /dev/null
  success "Vault unsealed on HTTPS"

  # Update credentials and Layer 2 tfvars with HTTPS address
  local tmp; tmp=$(mktemp)
  jq --arg addr "https://${NOMAD01_IP}:8200" '.vault_address = $addr' "$VAULT_CREDENTIALS_FILE" > "$tmp" && mv "$tmp" "$VAULT_CREDENTIALS_FILE"
  chmod 600 "$VAULT_CREDENTIALS_FILE"
  DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)
  initAndUnsealVault "$NOMAD01_IP"

  # Enable DNS records now that containers are deployed
  local SERVICES_TFVARS="${SCRIPT_DIR}/terraform/services/terraform.tfvars"
  if ! grep -q "deploy_dns_records" "$SERVICES_TFVARS" 2>/dev/null; then
    echo "deploy_dns_records = true" >> "$SERVICES_TFVARS"
  else
    sed -i.bak 's/deploy_dns_records.*/deploy_dns_records = true/' "$SERVICES_TFVARS"
    rm -f "$SERVICES_TFVARS.bak"
  fi

  # Re-apply Layer 2 with HTTPS Vault address + DNS records
  doing "Re-applying Layer 2 (HTTPS + DNS records)..."
  tf-services apply -auto-approve

  echo
  success "Deployment complete!"
  echo
  info "Services:"
  info "  Vault:   https://${NOMAD01_IP}:8200"
  info "  Traefik: http://${NOMAD01_IP}:8081"
  info "  Nomad:   http://${NOMAD01_IP}:4646"
  echo
}

# Rebuild Packer templates submenu
function rebuildTemplates() {
  echo
  echo -e "  ${C_BOLD}Rebuild Packer Templates${C_RESET}"
  echo
  echo "  a) All templates (base + service)"
  echo "  b) Base only (Ubuntu, Fedora, Debian)"
  echo "  s) Service only (Docker, Nomad)"
  echo "  q) Cancel"
  echo
  read -rp "$(question "Select: ")" tmpl_choice

  case $tmpl_choice in
    a|A)
      doing "Rebuilding all Packer templates..."
      docker compose build packer >/dev/null 2>&1
      docker compose run --rm packer init .
      docker compose run --rm packer build -only='base-*.*' .
      docker compose run --rm packer build -only='ubuntu-docker.*' -only='ubuntu-nomad.*' .
      success "All templates rebuilt"
      ;;
    b|B)
      doing "Rebuilding base templates..."
      docker compose build packer >/dev/null 2>&1
      docker compose run --rm packer init .
      docker compose run --rm packer build -only='base-*.*' .
      success "Base templates rebuilt"
      ;;
    s|S)
      doing "Rebuilding service templates..."
      docker compose build packer >/dev/null 2>&1
      docker compose run --rm packer init .
      docker compose run --rm packer build -only='ubuntu-docker.*' -only='ubuntu-nomad.*' .
      success "Service templates rebuilt"
      ;;
    *) info "Cancelled";;
  esac
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------
function showMenu() {
  echo -e "${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo
  echo -e "  ${C_BOLD}Setup${C_RESET}"
  echo "    1) Deploy all services"
  echo
  echo -e "  ${C_BOLD}Infrastructure (Layer 1)${C_RESET}"
  echo "    2) DNS (Pi-hole cluster)"
  echo "    3) Vault (deploy container)"
  echo "    4) Kasm Workspaces (optional)"
  echo "    5) Enable HA (keepalived VIPs)"
  echo
  echo -e "  ${C_BOLD}Services (Layer 2)${C_RESET}"
  echo "    6) Traefik (load balancer)"
  echo "    7) Authentik (SSO / OIDC)"
  echo "    8) Samba AD (domain controllers)"
  echo "    9) Uptime Kuma (monitoring)"
  echo "   10) LDAP Account Manager"
  echo
  echo -e "  ${C_BOLD}Management${C_RESET}"
  echo "   11) Rollback deployment"
  echo "   12) Purge deployment"
  echo "    0) Exit"

  if [ "$DEV_MODE" = true ]; then
    echo
    echo -e "  ${C_DIM}─── Developer Tools ──────────────────────${C_RESET}"
    echo
    echo "   d1) Rebuild Packer templates"
    echo "   d2) Reset API credentials"
    echo "   d3) Apply Layer 1 (infrastructure)"
    echo "   d4) Apply Layer 2 (services)"
    echo "   d5) Deploy Nomad cluster only"
    echo "   d6) Rebuild DNS records"
  fi
  echo
}

header

while true; do
  showMenu
  if [ "$DEV_MODE" = true ]; then
    read -rp "$(question "Select [0-12, d1-d6]: ")" choice
  else
    read -rp "$(question "Select [0-12]: ")" choice
  fi

  case $choice in
    1)  deployAll;;

    # Layer 1 — Infrastructure
    2)  ensureBootstrapComplete && tf apply -auto-approve -target=module.dns-main;;
    3)  ensureBootstrapComplete && tf apply -auto-approve -target=nomad_job.vault && initAndUnsealVault;;
    4)  ensureBootstrapComplete && tf apply -auto-approve -var "deploy_kasm=true";;
    5)  toggleHA;;

    # Layer 2 — Services
    6)  enableService "traefik";;
    7)  enableService "authentik";;
    8)  enableService "samba_dc";;
    9)  enableService "uptime_kuma";;
    10) enableService "lam";;

    # Management
    11) ensureBootstrapComplete && rollbackManual;;
    12) purgeDeployment;;

    # Developer tools
    d1|D1) if [ "$DEV_MODE" = true ]; then rebuildTemplates;                                            else error "Invalid option"; fi;;
    d2|D2) if [ "$DEV_MODE" = true ]; then resetProxmoxCredentials;                                     else error "Invalid option"; fi;;
    d3|D3) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf apply -auto-approve;            else error "Invalid option"; fi;;
    d4|D4) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf-services apply -auto-approve;  else error "Invalid option"; fi;;
    d5|D5) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf apply -auto-approve -target=module.nomad; else error "Invalid option"; fi;;
    d6|D6) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf-services apply -auto-approve -target=null_resource.pihole_dns_records -target=null_resource.pihole_nebula_sync -target=null_resource.proxmox_dns_config; else error "Invalid option"; fi;;

    0|q|Q) echo; info "Goodbye."; break;;
    *)     error "Invalid option: $choice";;
  esac

  # Skip pause if returning from submenu
  if [ "${SKIP_PAUSE:-false}" = "true" ]; then
    SKIP_PAUSE=false
  else
    echo
    read -rp "  Press Enter to continue..."
  fi
done
