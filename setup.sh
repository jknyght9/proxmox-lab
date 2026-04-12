#!/usr/bin/env bash
#
# Proxmox Lab — Interactive setup menu
#
# Driven entirely by bootstrap.yml. Option 1 reads the YAML, discovers the
# Proxmox cluster, creates API credentials, generates terraform.tfvars and
# packer.auto.pkrvars.hcl, then deploys the full stack.
#
# Usage:
#   ./setup.sh           # interactive menu
#   ./setup.sh --dev     # interactive menu with developer/beta options

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

# Cluster globals — populated by discoverCluster / loadClusterInfo
CLUSTER_NODES=()
CLUSTER_NODE_IPS=()
IS_CLUSTER=false
USE_SHARED_STORAGE=false
TEMPLATE_STORAGE=""
NETWORK_BRIDGE=""

# Deployment phase tracking for rollback
# 0=not started, 1=LXC deployed, 2=Packer built, 3=VMs deployed
DEPLOY_PHASE=0

# -----------------------------------------------------------------------------
# Main flow: full installation
# -----------------------------------------------------------------------------
function runEverything() {
  if [ ! -f "$SCRIPT_DIR/bootstrap.yml" ]; then
    error "bootstrap.yml not found."
    info "Copy bootstrap.yml.example to bootstrap.yml and edit it before running option 1."
    return 1
  fi

  checkRequirements
  generateSSHKeys
  generateServicePasswords

  # Read bootstrap.yml, discover cluster, create API token,
  # generate terraform.tfvars and packer.auto.pkrvars.hcl.
  runBootstrap || return 1

  # Distribute SSH keys to all discovered nodes
  distributeSSHKeys

  # Deploy services (LXC, Packer, VMs)
  deployAllServices

  # Setup Nomad cluster
  setupNomadCluster

  displayDeploymentSummary
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------
function showMenu() {
  echo
  echo "=========================================="
  echo "  Proxmox Lab - Main Menu"
  echo "=========================================="
  echo
  echo "  1) New installation (reads bootstrap.yml)"
  echo "  2) Deploy all services (DNS, CA, Nomad, Kasm)"
  echo "  3) Deploy critical services only (DNS, CA)"
  echo "  4) Deploy Traefik load balancer (on Nomad)"
  echo "  5) Deploy Vault secrets manager (on Nomad)"
  echo "  6) Deploy Authentik SSO (on Nomad)"
  echo "  7) Deploy Uptime Kuma monitoring (on Nomad)"
  echo "  8) Rollback service deployment (Terraform)"
  echo "  9) Purge service deployment (Emergency)"
  echo " 10) Purge entire deployment"
  echo "  0) Exit"

  if [ "$DEV_MODE" = true ]; then
    echo
    echo "------------------------------------------"
    echo "  Beta Features (experimental)"
    echo "------------------------------------------"
    echo
    echo " b1) Deploy Samba AD Domain Controllers (on Nomad)"
    echo " b2) Configure Authentik AD Sync"
    echo " b3) Configure automated backups (on Nomad)"
    echo " b4) Deploy LDAP Account Manager (on Nomad)"
    echo " b5) Deploy Vault with CA (PKI + ACME) [migration]"
    echo
    echo "------------------------------------------"
    echo "  Developer Tools"
    echo "------------------------------------------"
    echo
    echo " d1) Build DNS records"
    echo " d2) Regenerate CA"
    echo " d3) Update Proxmox root certificates"
    echo " d4) Reset Proxmox API credentials"
    echo " d5) Deploy Nomad only"
    echo " d6) Deploy Kasm only"
    echo " d7) Deploy Tailscale Subnet Router"
  fi
  echo
}

header

while true; do
  showMenu
  if [ "$DEV_MODE" = true ]; then
    read -rp "$(question "Select an option [0-10, b1-b5, d1-d7]: ")" choice
  else
    read -rp "$(question "Select an option [0-10]: ")" choice
  fi

  case $choice in
    1)  runEverything;;
    2)  deployAllServices;;
    3)  deployCriticalServicesOnly;;
    4)  deployTraefikOnly;;
    5)  deployVaultOnly;;
    6)  deployAuthentikOnly;;
    7)  deployUptimeKumaOnly;;
    8)  rollbackManual;;
    9)  purgeClusterResources;;
    10) purgeDeployment;;

    # Beta features (only available with --dev)
    b1|B1) if [ "$DEV_MODE" = true ]; then deploySambaADOnly;            else error "Invalid option: $choice"; fi;;
    b2|B2) if [ "$DEV_MODE" = true ]; then configureAuthentikADSyncOnly; else error "Invalid option: $choice"; fi;;
    b3|B3) if [ "$DEV_MODE" = true ]; then deployBackupOnly;             else error "Invalid option: $choice"; fi;;
    b4|B4) if [ "$DEV_MODE" = true ]; then deployLAMOnly;                else error "Invalid option: $choice"; fi;;
    b5|B5) if [ "$DEV_MODE" = true ]; then deployVaultWithCA;            else error "Invalid option: $choice"; fi;;

    # Developer tools (only available with --dev)
    d1|D1) if [ "$DEV_MODE" = true ]; then updateDNSRecords;          else error "Invalid option: $choice"; fi;;
    d2|D2) if [ "$DEV_MODE" = true ]; then regenerateCA;              else error "Invalid option: $choice"; fi;;
    d3|D3) if [ "$DEV_MODE" = true ]; then updateRootCertificates;    else error "Invalid option: $choice"; fi;;
    d4|D4) if [ "$DEV_MODE" = true ]; then resetProxmoxCredentials;   else error "Invalid option: $choice"; fi;;
    d5|D5) if [ "$DEV_MODE" = true ]; then deployNomadOnly;           else error "Invalid option: $choice"; fi;;
    d6|D6) if [ "$DEV_MODE" = true ]; then deployKasmOnly;            else error "Invalid option: $choice"; fi;;
    d7|D7) if [ "$DEV_MODE" = true ]; then deployTailscaleOnly;       else error "Invalid option: $choice"; fi;;

    0|q|Q) warn "Exiting..."; break;;
    *)     error "Invalid option: $choice";;
  esac

  # Skip pause if returning from submenu
  if [ "${SKIP_PAUSE:-false}" = "true" ]; then
    SKIP_PAUSE=false
  else
    echo
    read -rp "Press Enter to continue..."
  fi
done
