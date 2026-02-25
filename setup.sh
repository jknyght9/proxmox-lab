#!/usr/bin/env bash

set -euo pipefail
export TERM=xterm

# Library directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/ca/updateRootCertificates.sh"
source "$SCRIPT_DIR/lib/ca/util.sh"
source "$SCRIPT_DIR/lib/deploy/deployAllServices.sh"
source "$SCRIPT_DIR/lib/deploy/deployCriticalServices.sh"
source "$SCRIPT_DIR/lib/deploy/deployNomadJob.sh"
source "$SCRIPT_DIR/lib/deploy/displayDeploymentSummary.sh"
source "$SCRIPT_DIR/lib/deploy/purgeDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackManual.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployAuthentik.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployTraefik.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployVault.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/unsealVault.sh"
source "$SCRIPT_DIR/lib/deploy/configureVaultWIF.sh"
source "$SCRIPT_DIR/lib/deploy/configureNomadVaultIntegration.sh"
source "$SCRIPT_DIR/lib/deploy/vm/deployKasm.sh"
source "$SCRIPT_DIR/lib/deploy/vm/deployNomad.sh"
source "$SCRIPT_DIR/lib/proxmox/clusterHelpers.sh"
source "$SCRIPT_DIR/lib/proxmox/configureNetworking.sh"
source "$SCRIPT_DIR/lib/proxmox/configureProxmox.sh"
source "$SCRIPT_DIR/lib/proxmox/purgeClusterResources.sh"
source "$SCRIPT_DIR/lib/proxmox/selectNetworkBridge.sh"
source "$SCRIPT_DIR/lib/proxmox/selectSharedStorage.sh"
source "$SCRIPT_DIR/lib/proxmox/ssh.sh"
source "$SCRIPT_DIR/lib/proxmox/templateHelpers.sh"
source "$SCRIPT_DIR/lib/packerHelpers.sh"
source "$SCRIPT_DIR/lib/terraformHelpers.sh"
source "$SCRIPT_DIR/lib/updateDNSRecords.sh"
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/constants.sh"

PROXMOX_HOST="${1:-}"
PROXMOX_PASS="${2:-}"

# Global variables
CRYPTO_DIR="crypto"
DNS_POSTFIX=""
KEY_NAME="lab-deploy"
KEY_PATH="$CRYPTO_DIR/$KEY_NAME"
PUBKEY_PATH="$KEY_PATH.pub"
REMOTE_USER="root"

# Cluster-related globals (populated by detectAndSaveCluster or loadClusterInfo)
CLUSTER_INFO_FILE="cluster-info.json"
CLUSTER_NODES=()
CLUSTER_NODE_IPS=()
IS_CLUSTER=false
USE_SHARED_STORAGE=false
TEMPLATE_STORAGE="local-lvm"
NETWORK_BRIDGE="vmbr0"

# Network configuration globals (user-provided, stored in cluster-info.json)
EXT_CIDR=""
EXT_GATEWAY=""
DNS_START_IP=""
SVC_START_IP=""
CREATE_SDN=true
INT_CIDR=""
INT_GATEWAY=""

# Deployment phase tracking for rollback
# 0=not started, 1=LXC deployed, 2=Packer built, 3=VMs deployed
DEPLOY_PHASE=0

function runEverything() {
  checkRequirements
  generateSSHKeys
  checkProxmox
  installSSHKeys

  # Check if we have existing cluster info
  if [ -f "$CLUSTER_INFO_FILE" ] && jq -e '.network' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    read -rp "$(question "Found existing cluster-info.json. Use it? [Y/n]: ")" USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
    if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
      loadClusterInfo
    else
      detectAndSaveCluster
      configureNetworking
    fi
  else
    # Fresh setup - detect cluster and configure
    detectAndSaveCluster
    configureNetworking
  fi

  # Distribute SSH keys to all cluster nodes
  distributeSSHKeys

  # Select storage and network bridge (updates cluster-info.json)
  selectSharedStorage
  selectNetworkBridge

  # Save storage/bridge selection to cluster-info.json
  local tmp_file=$(mktemp)
  jq --arg storage "$TEMPLATE_STORAGE" \
     --arg storage_type "${TEMPLATE_STORAGE_TYPE:-lvm}" \
     --argjson shared "$USE_SHARED_STORAGE" \
     --arg bridge "$NETWORK_BRIDGE" \
     '. + {
       storage: { selected: $storage, type: $storage_type, is_shared: $shared },
       network: (.network + { selected_bridge: $bridge })
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  # Update terraform.tfvars from cluster-info.json
  updateTerraformFromClusterInfo

  # Run Proxmox setup on all nodes
  runProxmoxSetupOnAll

  # Optional post-install script
  proxmoxPostInstall

  # Deploy services (LXC, Packer, VMs)
  deployAllServices

  # Setup Nomad cluster
  setupNomadCluster

  displayDeploymentSummary
}

function runEverythingButSSH() {
  checkRequirements
  checkProxmox

  # Check if we have existing cluster info
  if [ -f "$CLUSTER_INFO_FILE" ] && jq -e '.network' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    read -rp "$(question "Found existing cluster-info.json. Use it? [Y/n]: ")" USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
    if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
      loadClusterInfo
    else
      detectAndSaveCluster
      configureNetworking
    fi
  else
    detectAndSaveCluster
    configureNetworking
  fi

  # Distribute SSH keys to all cluster nodes (assumes keys exist)
  if [ -f "$KEY_PATH" ]; then
    distributeSSHKeys
  fi

  # Select storage and network bridge
  selectSharedStorage
  selectNetworkBridge

  # Save storage/bridge selection to cluster-info.json
  local tmp_file=$(mktemp)
  jq --arg storage "$TEMPLATE_STORAGE" \
     --arg storage_type "${TEMPLATE_STORAGE_TYPE:-lvm}" \
     --argjson shared "$USE_SHARED_STORAGE" \
     --arg bridge "$NETWORK_BRIDGE" \
     '. + {
       storage: { selected: $storage, type: $storage_type, is_shared: $shared },
       network: (.network + { selected_bridge: $bridge })
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  # Update terraform.tfvars from cluster-info.json
  updateTerraformFromClusterInfo

  # Run Proxmox setup on all nodes
  runProxmoxSetupOnAll

  # Optional post-install script
  proxmoxPostInstall

  # Deploy services
  deployAllServices

  # Setup Nomad cluster
  setupNomadCluster

  displayDeploymentSummary
}

function showMenu() {
  echo
  echo "=========================================="
  echo "  Proxmox Lab - Main Menu"
  echo "=========================================="
  echo
  echo "  1) New installation"
  echo "  2) New installation - skip SSH key gen"
  echo "  3) Deploy all services (DNS, CA, Nomad, Kasm)"
  echo "  4) Deploy critical services only (DNS, CA)"
  echo "  5) Deploy Nomad only"
  echo "  6) Deploy Kasm only"
  echo "  7) Deploy Traefik load balancer (on Nomad)"
  echo "  8) Deploy Vault secrets manager (on Nomad)"
  echo "  9) Deploy Authentik SSO (on Nomad)"
  echo " 10) Build DNS records"
  echo " 11) Regenerate CA"
  echo " 12) Update Proxmox root certificates"
  echo " 13) Rollback service deployment (Terraform)"
  echo " 14) Purge service deployment (Emergency)"
  echo " 15) Purge entire deployment"
  echo "  0) Exit"
  echo
}

header

while true; do
  showMenu
  read -rp "$(question "Select an option [0-15]: ")" choice

  case $choice in
    1) runEverything;;
    2) runEverythingButSSH;;
    3) deployAllServices;;
    4) deployCriticalServicesOnly;;
    5) deployNomadOnly;;
    6) deployKasmOnly;;
    7) deployTraefikOnly;;
    8) deployVaultOnly;;
    9) deployAuthentikOnly;;
    10) updateDNSRecords;;
    11) regenerateCA;;
    12) updateRootCertificates;;
    13) rollbackManual;;
    14) purgeClusterResources;;
    15) purgeDeployment;;
    0|q|Q) warn "Exiting..."; break;;
    *) error "Invalid option: $choice";;
  esac

  # Skip pause if returning from submenu
  if [ "${SKIP_PAUSE:-false}" = "true" ]; then
    SKIP_PAUSE=false
  else
    echo
    read -rp "Press Enter to continue..."
  fi
done
