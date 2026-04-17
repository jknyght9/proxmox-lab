#!/usr/bin/env bash
#
# Proxmox Lab — Interactive setup menu
#
# Driven entirely by bootstrap.yml. Discovers the Proxmox cluster,
# creates API credentials, generates config files, and deploys the
# full stack using Packer + Terraform + Nomad.
#
# Usage:
#   ./setup.sh               # interactive menu
#   ./setup.sh --dev         # includes developer tools
#   ./setup.sh --debug       # verbose output (show all command output)
#   ./setup.sh --dev --debug # both

set -euo pipefail
export TERM=xterm

# Resolve project directory (script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# Library sourcing
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/bootstrap.sh"
source "$SCRIPT_DIR/lib/credentials.sh"

source "$SCRIPT_DIR/lib/ca/updateRootCertificates.sh"
source "$SCRIPT_DIR/lib/ca/util.sh"

source "$SCRIPT_DIR/lib/proxmox/clusterHelpers.sh"
source "$SCRIPT_DIR/lib/proxmox/configureProxmox.sh"
source "$SCRIPT_DIR/lib/proxmox/configureTailscale.sh"
source "$SCRIPT_DIR/lib/proxmox/purgeClusterResources.sh"
source "$SCRIPT_DIR/lib/proxmox/selectSharedStorage.sh"
source "$SCRIPT_DIR/lib/proxmox/ssh.sh"
source "$SCRIPT_DIR/lib/proxmox/templateHelpers.sh"

source "$SCRIPT_DIR/lib/packerHelpers.sh"
source "$SCRIPT_DIR/lib/terraformHelpers.sh"
source "$SCRIPT_DIR/lib/updateDNSRecords.sh"

source "$SCRIPT_DIR/lib/deploy/deployAllServices.sh"
source "$SCRIPT_DIR/lib/deploy/deployCriticalServices.sh"
source "$SCRIPT_DIR/lib/deploy/deployNomadJob.sh"
source "$SCRIPT_DIR/lib/deploy/displayDeploymentSummary.sh"
source "$SCRIPT_DIR/lib/deploy/purgeDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackManual.sh"
source "$SCRIPT_DIR/lib/deploy/configureVaultWIF.sh"
source "$SCRIPT_DIR/lib/deploy/configureNomadVaultIntegration.sh"

source "$SCRIPT_DIR/lib/deploy/nomadJob/deployAuthentik.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deploySambaAD.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/configureAuthentikADSync.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployBackup.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployTraefik.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployUptimeKuma.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployVault.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/unsealVault.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployTailscale.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployLAM.sh"

source "$SCRIPT_DIR/lib/deploy/vm/deployKasm.sh"
source "$SCRIPT_DIR/lib/deploy/vm/deployNomad.sh"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
DEV_MODE=false
DEBUG_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--dev" ]]   && DEV_MODE=true
  [[ "$arg" == "--debug" ]] && DEBUG_MODE=true
done
export DEBUG_MODE

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
  generateServicePasswords

  # Read bootstrap.yml, discover cluster, create API token,
  # generate terraform.tfvars and packer.auto.pkrvars.hcl.
  runBootstrap || return 1

  # Set PROXMOX_HOST from bootstrap (distributeSSHKeys and downstream use it)
  PROXMOX_HOST="$PROXMOX_IP"

  # Distribute SSH keys to all discovered nodes
  distributeSSHKeys

  # Deploy all services (DNS, Packer templates, Nomad, Vault, Kasm)
  deployAllServices

  displayDeploymentSummary
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
  echo -e "  ${C_BOLD}Core Services${C_RESET}"
  echo "    2) DNS (Pi-hole cluster)"
  echo "    3) Vault (secrets + PKI)"
  echo "    4) Traefik (load balancer)"
  echo
  echo -e "  ${C_BOLD}Authentication${C_RESET}"
  echo "    5) Authentik (SSO / OIDC)"
  echo "    6) Samba AD (domain controllers)"
  echo "    7) LDAP Account Manager"
  echo
  echo -e "  ${C_BOLD}Monitoring${C_RESET}"
  echo "    8) Uptime Kuma"
  echo "    9) Automated backups"
  echo
  echo -e "  ${C_BOLD}Management${C_RESET}"
  echo "   10) Rollback deployment"
  echo "   11) Purge deployment"
  echo "    0) Exit"

  if [ "$DEV_MODE" = true ]; then
    echo
    echo -e "  ${C_DIM}─── Developer Tools ──────────────────────${C_RESET}"
    echo
    echo "   d1) Build DNS records"
    echo "   d2) Rebuild Packer templates"
    echo "   d3) Regenerate CA certificates"
    echo "   d4) Update root certificates"
    echo "   d5) Reset API credentials"
    echo "   d6) Deploy Nomad only"
    echo "   d7) Deploy Kasm only"
    echo "   d8) Deploy Tailscale"
    echo "   d9) Configure Authentik AD Sync"
  fi
  echo
}

header

if [ "$DEBUG_MODE" = "true" ]; then
  warn "Debug mode enabled — full command output will be shown"
  echo
fi

while true; do
  showMenu
  if [ "$DEV_MODE" = true ]; then
    read -rp "$(question "Select [0-11, d1-d9]: ")" choice
  else
    read -rp "$(question "Select [0-11]: ")" choice
  fi

  case $choice in
    1)  deployAll;;
    2)  ensureBootstrapComplete && deployCriticalServicesOnly;;
    3)  ensureBootstrapComplete && deployVaultWithCA;;
    4)  ensureBootstrapComplete && deployTraefikOnly;;
    5)  ensureBootstrapComplete && deployAuthentikOnly;;
    6)  ensureBootstrapComplete && deploySambaADOnly;;
    7)  ensureBootstrapComplete && deployLAMOnly;;
    8)  ensureBootstrapComplete && deployUptimeKumaOnly;;
    9)  ensureBootstrapComplete && deployBackupOnly;;
    10) ensureBootstrapComplete && rollbackManual;;
    11) purgeDeployment;;

    # Developer tools (only available with --dev)
    d1|D1) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && updateDNSRecords;          else error "Invalid option"; fi;;
    d2|D2) if [ "$DEV_MODE" = true ]; then rebuildTemplates;                                     else error "Invalid option"; fi;;
    d3|D3) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && regenerateCA;              else error "Invalid option"; fi;;
    d4|D4) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && updateRootCertificates;    else error "Invalid option"; fi;;
    d5|D5) if [ "$DEV_MODE" = true ]; then resetProxmoxCredentials;                              else error "Invalid option"; fi;;
    d6|D6) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && deployNomadOnly;           else error "Invalid option"; fi;;
    d7|D7) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && deployKasmOnly;            else error "Invalid option"; fi;;
    d8|D8) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && deployTailscaleOnly;       else error "Invalid option"; fi;;
    d9|D9) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && configureAuthentikADSyncOnly; else error "Invalid option"; fi;;

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
