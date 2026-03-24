#!/usr/bin/env bash

set -euo pipefail
export TERM=xterm

# Library directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/ca/updateRootCertificates.sh"
source "$SCRIPT_DIR/lib/ca/util.sh"
source "$SCRIPT_DIR/lib/credentials.sh"
source "$SCRIPT_DIR/lib/deploy/deployAllServices.sh"
source "$SCRIPT_DIR/lib/deploy/deployCriticalServices.sh"
source "$SCRIPT_DIR/lib/deploy/deployNomadJob.sh"
source "$SCRIPT_DIR/lib/deploy/displayDeploymentSummary.sh"
source "$SCRIPT_DIR/lib/deploy/purgeDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackManual.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deployAuthentik.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/deploySambaAD.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/configureAuthentikADSync.sh"
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
source "$SCRIPT_DIR/lib/proxmox/configureTailscale.sh"
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

# Developer mode flag
DEV_MODE=false
for arg in "$@"; do
  if [[ "$arg" == "--dev" ]]; then
    DEV_MODE=true
  fi
done

# Global variables
CRYPTO_DIR="crypto"
DNS_POSTFIX=""
ENTERPRISE_KEY_NAME="labenterpriseadmin"
ENTERPRISE_KEY_PATH="$CRYPTO_DIR/$ENTERPRISE_KEY_NAME"
ENTERPRISE_PUBKEY_PATH="$ENTERPRISE_KEY_PATH.pub"
ADMIN_KEY_NAME="labadmin"
ADMIN_KEY_PATH="$CRYPTO_DIR/$ADMIN_KEY_NAME"
ADMIN_PUBKEY_PATH="$ADMIN_KEY_PATH.pub"
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
  generateServicePasswords
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
      # Distribute SSH keys before configureNetworking (which needs to SSH to all nodes)
      distributeSSHKeys
      configureNetworking
    fi
  else
    # Fresh setup - detect cluster and configure
    detectAndSaveCluster
    # Distribute SSH keys before configureNetworking (which needs to SSH to all nodes)
    distributeSSHKeys
    configureNetworking
  fi

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

  # Check/fix API credentials before setup (removes stale user if credentials missing locally)
  ensureProxmoxCredentials

  # Run Proxmox setup on all nodes (creates API token and captures credentials)
  runProxmoxSetupOnAll

  # Update terraform.tfvars and packer.auto.pkrvars.hcl with cluster config and API credentials
  updateTerraformFromClusterInfo
  updatePackerFromClusterInfo

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
  generateServicePasswords
  checkProxmox

  # Check if we have existing cluster info
  if [ -f "$CLUSTER_INFO_FILE" ] && jq -e '.network' "$CLUSTER_INFO_FILE" >/dev/null 2>&1; then
    read -rp "$(question "Found existing cluster-info.json. Use it? [Y/n]: ")" USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
    if [[ "$USE_EXISTING" =~ ^[Yy]$ ]]; then
      loadClusterInfo
      # Distribute SSH keys before configureNetworking (which needs to SSH to all nodes)
      if [ -f "$ENTERPRISE_KEY_PATH" ]; then
        distributeSSHKeys
      fi
    else
      detectAndSaveCluster
      # Distribute SSH keys before configureNetworking (which needs to SSH to all nodes)
      if [ -f "$ENTERPRISE_KEY_PATH" ]; then
        distributeSSHKeys
      fi
      configureNetworking
    fi
  else
    detectAndSaveCluster
    # Distribute SSH keys before configureNetworking (which needs to SSH to all nodes)
    if [ -f "$ENTERPRISE_KEY_PATH" ]; then
      distributeSSHKeys
    fi
    configureNetworking
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

  # Check/fix API credentials before setup (removes stale user if credentials missing locally)
  ensureProxmoxCredentials

  # Run Proxmox setup on all nodes (creates API token and captures credentials)
  runProxmoxSetupOnAll

  # Update terraform.tfvars and packer.auto.pkrvars.hcl with cluster config and API credentials
  updateTerraformFromClusterInfo
  updatePackerFromClusterInfo

  # Optional post-install script
  proxmoxPostInstall

  # Deploy services
  deployAllServices

  # Setup Nomad cluster
  setupNomadCluster

  displayDeploymentSummary
}

function reconfigureNetworking() {
  cat <<EOF

############################################################################
Network Configuration

Configure network settings including:
- External network CIDR and gateway
- DNS High Availability (keepalived VIP)
- Traefik High Availability (keepalived VIP)
- Internal SDN network (labnet)
- DNS domain suffix

This does NOT redeploy any services - it only updates configuration files.
After changing settings, you may need to redeploy affected services.
#############################################################################

EOF

  # Load existing cluster info
  if [ ! -f "$CLUSTER_INFO_FILE" ]; then
    error "cluster-info.json not found. Run option 1 or 2 first to initialize the cluster."
    return 1
  fi

  loadClusterInfo

  # Ensure SSH keys are distributed (configureNetworking needs to SSH to all nodes)
  if [ -f "$ENTERPRISE_KEY_PATH" ]; then
    distributeSSHKeys
  fi

  # Run network configuration
  configureNetworking

  # Update terraform.tfvars with new settings
  doing "Updating terraform.tfvars..."
  updateTerraformFromClusterInfo
  success "Network configuration updated"

  cat <<EOF

Next steps:
- If you changed Traefik HA settings: Redeploy Nomad (option 5) then Traefik (option 7)
- If you changed DNS HA settings: Redeploy DNS (option 4)
- If you only changed the DNS domain: Rebuild DNS records (--dev option d1)

EOF
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
  echo " 10) Deploy Samba AD Domain Controllers (on Nomad)"
  echo " 11) Configure Authentik AD Sync"
  echo " 12) Rollback service deployment (Terraform)"
  echo " 13) Purge service deployment (Emergency)"
  echo " 14) Purge entire deployment"
  echo "  0) Exit"

  if [ "$DEV_MODE" = true ]; then
    echo
    echo "------------------------------------------"
    echo "  Developer Tools"
    echo "------------------------------------------"
    echo
    echo " d1) Build DNS records"
    echo " d2) Regenerate CA"
    echo " d3) Update Proxmox root certificates"
    echo " d4) Configure networking"
    echo " d5) Reset labnet egress (fix DHCP/routing issues)"
    echo " d6) Reset Proxmox API credentials"
  fi
  echo
}

header

while true; do
  showMenu
  if [ "$DEV_MODE" = true ]; then
    read -rp "$(question "Select an option [0-14, d1-d6]: ")" choice
  else
    read -rp "$(question "Select an option [0-14]: ")" choice
  fi

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
    10) deploySambaADOnly;;
    11) configureAuthentikADSyncOnly;;
    12) rollbackManual;;
    13) purgeClusterResources;;
    14) purgeDeployment;;

    # Developer menu options (only available with --dev)
    d1|D1) if [ "$DEV_MODE" = true ]; then updateDNSRecords; else error "Invalid option: $choice"; fi;;
    d2|D2) if [ "$DEV_MODE" = true ]; then regenerateCA; else error "Invalid option: $choice"; fi;;
    d3|D3) if [ "$DEV_MODE" = true ]; then updateRootCertificates; else error "Invalid option: $choice"; fi;;
    d4|D4) if [ "$DEV_MODE" = true ]; then reconfigureNetworking; else error "Invalid option: $choice"; fi;;
    d5|D5) if [ "$DEV_MODE" = true ]; then resetLabnetEgress; else error "Invalid option: $choice"; fi;;
    d6|D6) if [ "$DEV_MODE" = true ]; then resetProxmoxCredentials; else error "Invalid option: $choice"; fi;;

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
