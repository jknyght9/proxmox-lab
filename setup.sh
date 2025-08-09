#!/bin/bash

set -euo pipefail
export TERM=xterm

PROXMOX_HOST="${1:-}"
PROXMOX_PASS="${2:-}"

# Global variables
CRYPTO_DIR="crypto"
KEY_NAME="lab-deploy"
KEY_PATH="$CRYPTO_DIR/$KEY_NAME"
PUBKEY_PATH="$KEY_PATH.pub"
REMOTE_USER="root"
REQUIRED_VMIDS=(903 904 905 906 907 908 909 910 911 912 913 9000 9001 9002 9100 9200)

# Colors for terminal outputs
C_RESET="\033[0m"
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[0;34m"

# Functions for convenience
function info()    { echo -e "${C_BLUE}[+] $*${C_RESET}"; }
function doing()   { echo -e "${C_BLUE}[>] $*${C_RESET}"; }
function success() { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
function error()   { echo -e "${C_RED}[X] $*${C_RESET}"; }
function warn()    { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
function question() { echo -e "  ${C_YELLOW}[?] $*${C_RESET}"; }

function header() {
  clear
  cat << "EOF"
   ___                                       __       _     
  / _ \_ __ _____  ___ __ ___   _____  __   / /  __ _| |__  
 / /_)/ '__/ _ \ \/ / '_ ` _ \ / _ \ \/ /  / /  / _` | '_ \ 
/ ___/| | | (_) >  <| | | | | | (_) >  <  / /__| (_| | |_) |
\/    |_|  \___/_/\_\_| |_| |_|\___/_/\_\ \____/\__,_|_.__/ 

EOF
}

function checkRequirements() {
  # Check if sshpass is installed
  if ! command -v sshpass >/dev/null 2>&1; then
    error "'sshpass' is not installed. Please install it and try again."
    echo "  Debian/Ubuntu: sudo apt install sshpass"
    echo "  macOS (Homebrew): brew install hudochenkov/sshpass/sshpass"
    echo "  Fedora: sudo dnf install sshpass"
    exit 1
  fi
}

function generateSSHKeys() {
    doing "Generating SSH keys for deployment..."
    mkdir -p "$CRYPTO_DIR"

    # Check if key already exists
    if [[ -f "$KEY_PATH" ]]; then
      warn "SSH key already exists at $KEY_PATH"
      read -rp "$(question "Do you want to overwrite it? [y/N]: ")" confirm
      [[ ! "$confirm" =~ ^[Yy]$ ]] && info "Continuing without changes..." && return 0
    fi

    # Generate key (always runs if key doesn't exist or confirmed overwrite)
    ssh-keygen -t ed25519 -f "$KEY_PATH" -C "lab-deploy" -N "" || {
      error "SSH key generation failed."
      exit 1
    }
    chmod 600 "$KEY_PATH"
    chmod 600 "$KEY_PATH".pub

    success "SSH key pair generated:"
    echo "    Private key: $KEY_PATH"
    echo "    Public key:  $KEY_PATH.pub"
}

function checkProxmox() {
  header
  info "Requesting Proxmox information"

  if [[ -z "$PROXMOX_HOST" ]]; then
    read -rp "$(question "Enter the IP address or hostname of the Proxmox server: ")" PROXMOX_HOST
  fi

  if [[ -z "$PROXMOX_PASS" ]]; then
    read -s -rp "$(question "Enter the root password for $PROXMOX_HOST: ")" PROXMOX_PASS
    echo
  fi

  doing "Checking connectivity to $PROXMOX_HOST..."
  if ! ping -c 1 -W 2 "$PROXMOX_HOST" >/dev/null 2>&1; then
    error "Cannot reach $PROXMOX_HOST (ping failed)"
    exit 1
  fi

  doing "Testing SSH connection to $REMOTE_USER@$PROXMOX_HOST..."
  if ! sshpass -p "$PROXMOX_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_USER@$PROXMOX_HOST" "echo SSH connection successful" >/dev/null 2>&1; then
    error "SSH connection failed. Check password or network."
    exit 1
  fi
  success "Successfully connected to $PROXMOX_HOST.\n"
}

function installSSHKeys() {
  doing "Installing SSH public key..."
  sshpass -p "$PROXMOX_PASS" ssh "$REMOTE_USER@$PROXMOX_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  sshpass -p "$PROXMOX_PASS" scp "$PUBKEY_PATH" "$REMOTE_USER@$PROXMOX_HOST":/root/.ssh/$KEY_NAME.pub
  sshpass -p "$PROXMOX_PASS" ssh "$REMOTE_USER@$PROXMOX_HOST" \
  "grep -qxF '$(cat "$PUBKEY_PATH")' ~/.ssh/authorized_keys \
    || (echo '$(cat "$PUBKEY_PATH")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys)"
  success "Public key installed successfully on $PROXMOX_HOST.\n"
}

function proxmoxPostInstall() {
  doing "Running Proxmox VE Post-Installation Script..."
  read -rp "$(question "Do you want to run the Proxmox VE Post-Install script now? This is optional, but highly recommended (y/N): ")" RUN_POST_SCRIPT
  if [[ "$RUN_POST_SCRIPT" =~ ^[Yy]$ ]]; then
    doing "Running Proxmox VE Post-Install Script..."

    if [ ! -f "$KEY_PATH" ]; then
      error "SSH private key not found at $KEY_PATH"
      exit 1
    fi
    
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"'
    success "Completed post-installation on $PROXMOX_HOST.\n"
  else
    warn "Skipped running the post-install script.\n"
  fi
}

function proxmoxLabInstall() {
  doing "Running Proxmox VE Lab Install Script..."
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no ./proxmox/setup.sh "$REMOTE_USER@$PROXMOX_HOST":/root/
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" 'bash -c "chmod +x /root/setup.sh && /root/setup.sh"'
  success "Completed the lab installation script on $PROXMOX_HOST\n"
}

function generateCertificates() {
  doing "Setting up step-ca for certificate generation"
  STEPCA_DIR="terraform/lxc-step-ca/step-ca"
  if [ ! -d "$STEPCA_DIR" ]; then
    mkdir -p terraform/lxc-step-ca/step-ca
  fi
  docker compose run --rm -it step-ca
  success "Certificate generation complete.\n"
}

function deployServices() {
  cat << "EOF"

############################################################################
Services Deployment

Next, we will setup critical services for the lab. This includes secured DNS
(Pihole, Unbound, & dnscrypt-proxy), a certificate authority (Step-CA), KASM
and a Docker Swarm cluster. At this time, you will configure the DNS suffix 
(.lab, .com, .io, lab.io), and the Pihole web UI administrator passwords.

Please make sure that you update your packer.auto.pkvars.hcl and 
terraform.tfvars before starting this process.
#############################################################################

EOF
  read -n 1 -s -p "$(question "Press any key to continue")"
  echo

  while true; do
      # Prompt for values with defaults
      read -rp "$(question "Enter DNS domain postfix without a period [lab]: ")" DNS_POSTFIX
      DNS_POSTFIX=${DNS_POSTFIX:-lab}

      read -rp "$(question "Enter PiHole webserver API password [changeme123]: ")" PIHOLE_PASSWORD
      PIHOLE_PASSWORD=${PIHOLE_PASSWORD:-changeme123}

      # Display configuration summary
      echo ""
      echo "======================================"
      echo "Configuration Summary:"
      echo "--------------------------------------"
      echo ""
      echo "DNS suffix:             $DNS_POSTFIX"
      echo "Pihole Web API pass:    $PIHOLE_PASSWORD"
      echo "======================================"
      echo ""

      # Ask user to confirm
      read -rp "$(question "Is this correct? [y/N]: ")" CONFIRM
      echo
      CONFIRM=${CONFIRM:-N}

      if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
          break
      fi

      warn "Let's try again..."
  done

  # Update the step-ca installation script with new DNS postfix
  if sed --version >/dev/null 2>&1; then
      sed -i "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
  else
      sed -i '' "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
  fi
  success "Step-CA installation script updated successfully!"
  generateCertificates

  # Update the pihole installation script with new password
  if sed --version >/dev/null 2>&1; then
      sed -i "s/^WEBSERVER_PASSWORD=.*/WEBSERVER_PASSWORD=\"$PIHOLE_PASSWORD\"/" terraform/lxc-pihole/install.sh
  else
      sed -i '' "s/^WEBSERVER_PASSWORD=.*/WEBSERVER_PASSWORD=\"$PIHOLE_PASSWORD\"/" terraform/lxc-pihole/install.sh
  fi
  success "Pihole installation script updated successfully!"

  # Checking VMIDs
  doing "Checking if required Proxmox VMIDs currently exist..."
  manageVMIDs "${REQUIRED_VMIDS[@]}"
  success "VMID check complete\n"

  # Create the LXC container
  createPiholeTemplate
  read -n 1 -s -p "$(question "Press any key to continue")"
  echo

  # Build packer templates
    cat << "EOF"
#############################################################################
Template creation

During this section, packer will begin creating the templates required for 
this lab. Please make sure that you update your packer.auto.pkvars.hcl before
starting this process.
#############################################################################
EOF
  read -n 1 -s -p "$(question "Press any key to continue")"
  echo

  doing "Building Packer templates..."
  docker compose build packer >/dev/null 2>&1
  docker compose run --rm -it packer init .
  if docker compose run --rm -it packer build .; then
      success "Packer build succeeded"
  else
      error "Packer build was not successful, please review the logs"
      exit 1
  fi

  cat << "EOF"
#############################################################################
Template deployment

During this section, terraform will begin deploying the packer templates and 
LXC containers required for this lab. Please make sure that you update your
terraform.tfvars before starting this process.
#############################################################################
EOF
  read -n 1 -s -p "$(question "Press any key to continue")"
  echo

  doing "Deploying terraform templates..."
  docker compose build terraform >/dev/null 2>&1
  docker compose run --rm -it terraform init
  docker compose run --rm -it terraform plan
  docker compose run --rm -it terraform apply
  docker compose run --rm -it terraform refresh
  docker compose run --rm -it terraform output -json host-records > hosts.json
}

# Because packer doesnt support LXC
function createPiholeTemplate() {
  local TEMPLATE_VMID=9000
  local TEMPLATE_NAME="pihole-template"
  local OSTEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
  local STORAGE="local-lvm"
  local BRIDGE="vmbr1"
  local CORES=2
  local MEMORY=2048

  doing "Creating LXC container for Pihole"
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no ./terraform/lxc-pihole/install.sh "$REMOTE_USER@$PROXMOX_HOST":/root/
  
  doing "Creating LXC container ${TEMPLATE_VMID} (${TEMPLATE_NAME})..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" \
    "pct stop ${TEMPLATE_VMID} || true > /dev/null 2>&1 && pct destroy ${TEMPLATE_VMID} || true > /dev/null 2>&1"
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" \
    "pct create ${TEMPLATE_VMID} ${OSTEMPLATE} \
      --hostname ${TEMPLATE_NAME} \
      --cores ${CORES} \
      --memory ${MEMORY} \
      --net0 name=eth0,bridge=${BRIDGE},ip=dhcp \
      --start
    pct set ${TEMPLATE_VMID} -features nesting=1,keyctl=1
    pct exec ${TEMPLATE_VMID} -- bash -c '
      mkdir -p /root/.ssh &&
      chmod 700 /root/.ssh &&
      touch /root/.ssh/authorized_keys &&
      chmod 600 /root/.ssh/authorized_keys'
    pct push ${TEMPLATE_VMID} /root/.ssh/lab-deploy.pub /root/lab-deploy.pub
    pct exec ${TEMPLATE_VMID} -- bash -c 'cat /root/lab-deploy.pub >> /root/.ssh/authorized_keys && rm /root/lab-deploy.pub'
    pct reboot ${TEMPLATE_VMID}"

  doing "Running installation script..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "\
    pct push ${TEMPLATE_VMID} /root/install.sh /root/install.sh && \
    pct exec ${TEMPLATE_VMID} -- bash -c 'bash /root/install.sh'" || true

  doing "Cleaning container for template..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" "pct exec ${TEMPLATE_VMID} -- bash -c 'apt-get clean && \
    rm -rf /tmp/* /var/tmp/* /var/log/* /root/.bash_history && \
    truncate -s 0 /etc/machine-id && \
    rm -f /etc/ssh/ssh_host_* && \
    ssh-keygen -A && \
    systemctl enable ssh'"

  doing "Stopping container and converting to template..."
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" "pct stop ${TEMPLATE_VMID} && pct template ${TEMPLATE_VMID}"
  success "LXC creation complete"
}

function manageVMIDs() {
  local VMIDS=("$@")

  for VMID in "${VMIDS[@]}"; do
    # Check if QEMU VM exists
    if ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "qm config $VMID" &>/dev/null; then
      warn "VMID $VMID is a QEMU VM"
      read -rp "$(question "Do you want to destroy VMID $VMID (y/N)? ")" REPLY
      if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        ssh -i "$KEY_PATH" "$REMOTE_USER@$PROXMOX_HOST" "qm stop $VMID || true && qm destroy $VMID || true"
        success "QEMU VM $VMID destroyed."
      fi

    # Check if LXC container exists
    elif ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "pct config $VMID" &>/dev/null; then
      warn "VMID $VMID is an LXC container"
      read -rp "$(question "Do you want to destroy VMID $VMID (y/N)? ")" REPLY
      if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        ssh -i "$KEY_PATH" "$REMOTE_USER@$PROXMOX_HOST" "pct stop $VMID || true && pct destroy $VMID || true"
        success "LXC container $VMID destroyed."
      fi

    else
      info "VMID $VMID does not exist"
    fi
  done
}

function updateDNSRecords() {
  doing "Updating DNS records."
  PIHOLE_IP=$(jq -r '.external[] | select(.hostname == "pihole-external") | .ip' hosts.json | cut -d'/' -f1)
  EXT_RECORDS=$(jq -r --arg suffix "$DNS_POSTFIX" \
    '[.external[] | "\(.ip | split("/")[0]) \(.hostname) \(.hostname).\($suffix)"] | @json' hosts.json)
  PVE_HOSTNAME=$(ssh -i "$KEY_PATH" "$REMOTE_USER@$PROXMOX_HOST" "hostname")
  UPDATED_RECORDS=$(jq -n \
    --argjson ext "$EXT_RECORDS" \
    --arg pveip "$PROXMOX_HOST" \
    --arg pvename "$PVE_HOSTNAME" \
    --arg suffix "$DNS_POSTFIX" \
    '$ext + [($pveip + " " + $pvename + " " + $pvename + "." + $suffix)]'
  )
  ssh -i "$KEY_PATH" "$REMOTE_USER@$PIHOLE_IP" "pihole-FTL --config dns.hosts '$UPDATED_RECORDS' \
    && pihole-FTL --config dns.cnameRecords '[\"ca.$DNS_POSTFIX, step-ca.$DNS_POSTFIX\"]'"
  ssh -i "$KEY_PATH" "$REMOTE_USER@$PROXMOX_HOST" "pvesh set /nodes/pve/dns -dns1 $PIHOLE_IP -search $DNS_POSTFIX" 
}

function updateRootCertificates() {
  DNS_POSTFIX="jdclabs.io"

  doing "Updating root certificates on Proxmox"
  CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json | cut -d'/' -f1)
  curl -ko proxmox-lab-root-ca.crt https://$CA_IP/roots.pem
  scp proxmox-lab-root-ca.crt "$REMOTE_USER@$PROXMOX_HOST:/usr/local/share/ca-certificates/proxmox-lab-root-ca.crt"
  ssh -i "$KEY_PATH" "$REMOTE_USER@$PROXMOX_HOST" "update-ca-certificates \
    && pvenode acme account register default admin@example.com --directory https://ca.$DNS_POSTFIX/acme/acme/directory \
    && pvenode config set --acme domains=$DNS_POSTFIX \
    && pvenode acme cert order"
}

function destroyLab() {
  checkProxmox
  doing "Destroying lab..."
  manageVMIDs "${REQUIRED_VMIDS[@]}"
  if docker compose run --rm -it terraform destroy; then
    success "Destruction complete.\n"
  else 
    error "An error occurred during lab destruction"
    exit 1
  fi
  ssh -i "$KEY_PATH" "$REMOTE_USER@$PROXMOX_HOST" 'bash /root/setup.sh destroy'
  info "Destruction complete"
}

function runEverything() {
  checkRequirements
  generateSSHKeys
  checkProxmox
  installSSHKeys
  proxmoxPostInstall
  proxmoxLabInstall
  deployServices
  updateDNSRecords
  updateRootCertificates
}

function runEverythingButSSH() {
  checkRequirements
  checkProxmox
  proxmoxPostInstall
  proxmoxLabInstall
  deployServices
  updateDNSRecords
  updateRootCertificates
}

header
options=("New installation" "Rerun everything but SSH key gen" "Rerun deploy services" "Build DNS records" "Update Root Certificates" "Destroy lab" "Exit")
select opt in "${options[@]}"; do
  case $REPLY in
    1) runEverything;;
    2) runEverythingButSSH;;
    3) deployServices;;
    4) updateDNSRecords;;
    5) updateRootCertificates;;
    6) destroyLab;;
    7) warn "Exiting..."; break;;
    *) echo "Invalid option";;
  esac
done
