#!/bin/bash

set -euo pipefail
export TERM=xterm

PROXMOX_HOST="${1:-}"
PROXMOX_PASS="${2:-}"

# Global variables
CRYPTO_DIR="crypto"
DNS_POSTFIX=""
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
function info()         { echo -e "${C_BLUE}[+] $*${C_RESET}"; }
function doing()        { echo -e "${C_BLUE}[>] $*${C_RESET}"; }
function success()      { echo -e "${C_GREEN}[✓] $*${C_RESET}"; }
function error()        { echo -e "${C_RED}[X] $*${C_RESET}"; }
function warn()         { echo -e "${C_YELLOW}[!] $*${C_RESET}"; }
function question()     { echo -e "  ${C_YELLOW}[?] $*${C_RESET}"; }
function sshRun()       { ssh -i $KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$1@$2" "$3"; }
function pressAnyKey()  { read -n 1 -s -p "$(question "Press any key to continue")"; echo; }

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
  
  # Check if jq is installed
  if ! command -v jq >/dev/null 2>&1; then
    error "'jq' is not installed. Please install it and try again."
    echo "  Debian/Ubuntu: sudo apt install jq"
    echo "  macOS (Homebrew): brew install jq"
    echo "  Fedora: sudo dnf install jq"
    exit 1
  fi

  # Check if Docker Engine is installed
  if ! command -v docker >/dev/null 2>&1; then
    error "'docker' is not installed. Please install Docker Engine."
    echo "  https://docs.docker.com/engine/install/"
    exit 1
  fi

  # Check if Docker Engine is running
  if ! docker info >/dev/null 2>&1; then
    error "Docker Engine is installed but not running or not accessible."
    echo "  Make sure the docker service is started:"
    echo "    sudo systemctl start docker"
    echo "  Or check permissions (your user may need to be in the 'docker' group)."
    exit 1
  fi

  success "All requirements met: sshpass, jq, and Docker are available and running."
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
    
    sshRun $REMOTE_USER $PROXMOX_HOST 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"'
    #ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"'
    success "Completed post-installation on $PROXMOX_HOST.\n"
  else
    warn "Skipped running the post-install script.\n"
  fi
}

function proxmoxLabInstall() {
  doing "Running Proxmox VE Lab Install Script..."
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no ./proxmox/setup.sh "$REMOTE_USER@$PROXMOX_HOST":/root/
  #sshRun $REMOTE_USER $PROXMOX_HOST 'bash -c "chmod +x /root/setup.sh && /root/setup.sh"'
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
  cat <<EOF

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
      cat <<EOF

======================================
Configuration Summary:
--------------------------------------

DNS suffix:             $DNS_POSTFIX
Pihole Web API pass:    $PIHOLE_PASSWORD
======================================

EOF
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
    cat <<EOF

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

  cat <<EOF

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
  local STORAGE="local-lvm"
  local BRIDGE="vmbr0"
  local CORES=2
  local MEMORY=2048

  doing "Creating LXC container for Pihole"
  scp -i "$KEY_PATH" -o StrictHostKeyChecking=no ./terraform/lxc-pihole/install.sh "$REMOTE_USER@$PROXMOX_HOST":/root/
  
  doing "Creating LXC container ${TEMPLATE_VMID} (${TEMPLATE_NAME})..."
  local OSTEMPLATE=$(sshRun $REMOTE_USER $PROXMOX_HOST "pveam list local | awk '/vztmpl/ {print \$1; exit}'")
  echo $OSTEMPLATE
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" "\
    pct stop ${TEMPLATE_VMID} || true > /dev/null 2>&1 && pct destroy ${TEMPLATE_VMID} || true > /dev/null 2>&1
    pct create ${TEMPLATE_VMID} ${OSTEMPLATE} \
      --storage ${STORAGE} \
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
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -t "$REMOTE_USER@$PROXMOX_HOST" "pct stop ${TEMPLATE_VMID} && pct template ${TEMPLATE_VMID} && pct set ${TEMPLATE_VMID} -ostype debian"
  success "LXC creation complete"
}

function setupDockerSwarm() {
  BRICK="/gluster/volume1"
  VOL="swarm-data"
  MOUNTPOINT="/srv/gluster/${VOL}"
  SSH_USERNAME=$(jq -r '.[] | select(.build | contains("docker")) | .ssh_username' packer/packer-outputs/template-credentials.json)
  
  doing "Setting up docker swarm"
  NODE_IPS=()
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && NODE_IPS+=("$ip")
  done < <(
    jq -r '.external[] | select(.hostname | contains("docker")) | .ip' hosts.json \
    | sed 's:/.*$::'
  )
  
  if ((${#NODE_IPS[@]} < 1)); then
    echo "No hosts found to configure."
    exit 1
  fi

  MGR="${NODE_IPS[0]}"
  ND1="${NODE_IPS[1]}"
  ND2="${NODE_IPS[2]}"

  # doing "Ensuring GlusterFS is running on nodes"
  # for ip in "${NODE_IPS[@]}"; do
  #   sshRun "$ip" "systemctl enable --now glusterd || systemctl enable --now glusterfsd || true"
  #   sshRun "$ip" "mkdir -p '$BRICK'"
  # done 

  # Probe peers
  for peer in "${NODE_IPS[@]}"; do
    if ! sshRun "$REMOTE_USER" "$MGR" "gluster pool list | awk '{print \$2}' | grep -qx '$peer'"; then 
      doing "Probing peer $peer"
      sshRun "$REMOTE_USER" "$MGR" "gluster peer probe $peer"
    else 
      info "$peer is already in pool"
    fi
  done

  sleep 2

  # # Wait for connections
  # for peer in "${NODE_IPS[@]}"; do
  #   until sshRun "$REMOTE_USER" "$MGR" "gluster peer status | grep -A1 -w '$peer' | grep -q Connected"; do
  #     sleep 2
  #   done
  # done

  # sleep 2

  # Create and start volume
  BRICKS="$MGR:$BRICK $ND1:$BRICK $ND2:$BRICK"
  if ! sshRun "$REMOTE_USER" "$MGR" "gluster volume info $VOL >/dev/null 2>&1"; then
    doing "Creating volume $VOL"
    sshRun "$REMOTE_USER" "$MGR" "gluster volume create $VOL replica 3 $BRICKS force"
  else
    info "Volume $VOL exists"
  fi

  if ! sshRun "$REMOTE_USER" "$MGR" "gluster volume status $VOL >/dev/null 2>&1"; then
    doing "Starting volume $VOL"
    sshRun "$REMOTE_USER" "$MGR" "gluster volume start $VOL"
  fi

  sleep 2

  # Set recommended options
  for opt in \
    "cluster.quorum-type auto" \
    "cluster.self-heal-daemon on" \
    "cluster.data-self-heal on" \
    "cluster.metadata-self-heal on" \
    "cluster.entry-self-heal on" \
    "performance.client-io-threads on" \
    "network.ping-timeout 10"
  do
    sshRun "$REMOTE_USER" "$MGR" "gluster volume set $VOL $opt || true"
  done

  sleep 2

  # Mount with fstab
  PREF="$MGR"
  BACKUPS=$(printf ",backupvolfile-server=%s" "$ND1" "$ND2")
  for ip in "${NODE_IPS[@]}"; do
    doing "Mounting on $ip"
    sshRun "$REMOTE_USER" "$ip" "mkdir -p '$MOUNTPOINT'"
    sshRun "$REMOTE_USER" "$ip" "sed -i \"/:${VOL}[[:space:]]/d\" /etc/fstab"
    sshRun "$REMOTE_USER" "$ip" "echo '${PREF}:/${VOL} ${MOUNTPOINT} glusterfs defaults,_netdev${BACKUPS} 0 0' | tee -a /etc/fstab >/dev/null"
    sshRun "$REMOTE_USER" "$ip" "mount -a || mount.glusterfs ${PREF}:/${VOL} ${MOUNTPOINT}"
  done

  sleep 2

  # Verify
  sshRun "$REMOTE_USER" "$MGR" "gluster volume info $VOL"
  sshRun "$REMOTE_USER" "$MGR" "gluster volume status $VOL"
  sshRun "$REMOTE_USER" "$MGR" "gluster volume heal $VOL info || true"

  success "GlusterFS '$VOL' up on: ${NODE_IPS[*]}"
  info "Mounted at ${MOUNTPOINT} on each node."

  NODES=("${NODE_IPS[@]:1}")

  info "Manager Primary: $MGR"
  info "Managers: ${NODES[*]:-<none>}"

  doing "Initializing docker swarm primary manager $MGR"
  sshRun "$REMOTE_USER" "$MGR" "docker swarm init --advertise-addr $MGR || true"
  MANAGER_TOKEN=$(sshRun "$REMOTE_USER" "$MGR" "docker swarm join-token -q manager")
  WORKER_TOKEN=$(sshRun "$REMOTE_USER" "$MGR" "docker swarm join-token -q worker")

  sleep 2
  
  doing "Adding additional nodes to swarm"
  for ip in "${NODES[@]}"; do
    info "Manager join: $ip"
    sshRun "$REMOTE_USER" "$ip" "sudo docker swarm join --token $MANAGER_TOKEN $MGR:2377 || true"
  done

  sleep 2

  doing "Adding Portainer to swarm"
  PORTAINER_DIR=${BRICK}/portainer
  PORTAINER_FILE=${PORTAINER_DIR}/portainer-agent-stack.yml
  PORTAINER_SERVICE_DIR=${BRICK}/services/portainer

  sshRun "$REMOTE_USER" "$MGR" "mkdir -p ${PORTAINER_DIR} ${PORTAINER_SERVICE_DIR} \
    && curl -L https://downloads.portainer.io/ce-lts/portainer-agent-stack.yml -o ${PORTAINER_FILE} \
    && sed -i 's|portainer_data:/data|/gluster/volume1/services/portainer:/data|' ${PORTAINER_FILE} \
    && docker stack deploy -c ${PORTAINER_FILE} portainer \
    && docker node ls \
    && docker service ls \
    && gluster pool list"
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
  if [ -z "${DNS_POSTFIX}" ]; then
    read -rp "Enter your DNS suffix: " DNS_POSTFIX
  fi

  doing "Reading Proxmox node member map from $PROXMOX_HOST:/etc/pve/.members"
  local MEMBERS_JSON
  MEMBERS_JSON="$(sshRun "$REMOTE_USER" "$PROXMOX_HOST" "cat /etc/pve/.members")"

  doing "Generating Proxmox node DNS records."
  local NODE_RECORDS_JSON
  NODE_RECORDS_JSON="$(jq -c --arg suffix "$DNS_POSTFIX" '.nodelist | to_entries | map("\(.value.ip) \(.key) \(.key)." + $suffix)' <<<"$MEMBERS_JSON")"
  NODE_RECORDS_ALIAS_JSON="$(jq -c --arg prefix "proxmox" --arg suffix "$DNS_POSTFIX" '.nodelist | to_entries | map("\(.value.ip) \($prefix) \($prefix + "." + $suffix)")' <<<"$MEMBERS_JSON")"

  doing "Generating other DNS records."
  local EXT_RECORDS_JSON
  local PIHOLE_IP
  if [ -s hosts.json ]; then
    EXT_RECORDS_JSON="$(jq -c --arg suffix "$DNS_POSTFIX" \
      '(.external // []) | map("\((.ip | split("/")[0])) \(.hostname) \(.hostname)." + $suffix)' hosts.json)"
    PIHOLE_IP=$(jq -r '.external[] | select(.hostname == "pihole-external") | .ip' hosts.json | cut -d'/' -f1)
  else
    warn "Hosts.json was not found"
  fi 

  local ALL_DNS_RECORDS_JSON
  ALL_DNS_RECORDS_JSON="$(jq -c -n --argjson a "$NODE_RECORDS_JSON" --argjson b "$EXT_RECORDS_JSON" --argjson c "$NODE_RECORDS_ALIAS_JSON" '$a + $b + $c')"

  doing "Updating Pi-hole @ $PIHOLE_IP with $(jq -r 'length' <<<"$ALL_DNS_RECORDS_JSON") A-records"
  sshRun "$REMOTE_USER" "$PIHOLE_IP" "
    pihole-FTL --config dns.hosts '$ALL_DNS_RECORDS_JSON' &&
    pihole-FTL --config dns.cnameRecords '[\"ca.$DNS_POSTFIX, step-ca.$DNS_POSTFIX\"]'
  "
  
  doing "Updating Proxmox's DNS servers..."
  NODE_NAMES=()
  while IFS= read -r name; do
    NODE_NAMES+=("$name")
  done < <(jq -r '.nodelist | keys[]' <<<"$MEMBERS_JSON")
  for name in "${NODE_NAMES[@]}"; do 
    sshRun "$REMOTE_USER" "$PROXMOX_HOST" \
      "pvesh set /nodes/$name/dns -dns1 $PIHOLE_IP -dns2 1.1.1.1 -search $DNS_POSTFIX"
  done 
  success "Pihole-external DNS records updated"
}

function updateRootCertificates() {
  if [ -z "${DNS_POSTFIX}" ]; then
    read -rp "Enter your DNS suffix: " DNS_POSTFIX
  fi

  if [ -s hosts.json ]; then
    CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json | cut -d'/' -f1)
  fi
  if [[ -z "$CA_IP" ]]; then
    read -rp "Enter CA IP address: " CA_IP
  fi

  local CA_URL="https://$CA_IP/roots.pem"
  local ACME_DIR="https://ca.${DNS_POSTFIX}/acme/acme/directory"

  doing "Reading node list from ${PROXMOX_HOST}:/etc/pve/.members"
  local MEMBERS_JSON
  MEMBERS_JSON="$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" 'cat /etc/pve/.members')"
  local NODE_IPS=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && NODE_IPS+=("$name")
  done < <(jq -r '.nodelist | to_entries[] | .value.ip' <<<"$MEMBERS_JSON")

  if ((${#NODE_IPS[@]}==0)); then
    error "No nodes found in /etc/pve/.members"; return 1
  fi

  doing "Downloading Step CA root bundle: $CA_URL"
  curl -fsS -k -o proxmox-lab-root-ca.crt "$CA_URL" || { echo "Failed to fetch $CA_URL"; return 1; }

  doing "Installing root CA on all nodes and updating trust"
  for name in "${NODE_IPS[@]}"; do
    echo "  - $name"
    scp -i "$KEY_PATH" -o StrictHostKeyChecking=no proxmox-lab-root-ca.crt \
      "$REMOTE_USER@$name:/usr/local/share/ca-certificates/proxmox-lab-root-ca.crt"
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$name" "
      set -e
      update-ca-certificates
      systemctl reload pveproxy || systemctl restart pveproxy
    "
  done

  doing "Registering ACME account 'default' against Step CA directory"
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$PROXMOX_HOST" "
    pvenode acme account register default admin@example.com --directory '$ACME_DIR' || true
  "

  doing "Ordering/renewing certs per node"
  exec 3< <(jq -r '.nodelist | to_entries[] | "\(.key)\t\(.value.ip)"' <<<"$MEMBERS_JSON")
  while IFS=$'\t' read -r name ip <&3; do
    [[ -z "$name" || -z "$ip" ]] && continue
    fqdn="${name}.${DNS_POSTFIX}"
    pmfqdn="proxmox.${DNS_POSTFIX}"
    acme_map="account=default,domains=${fqdn};${pmfqdn}"
    
    info "  - $name ($ip) -> $fqdn (+ ${pmfqdn})"
    
    ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$ip" "
      set -e
      pvenode config set --acme \"$acme_map\"
      pvenode acme cert order -force
    " || { warn "SSH/ACME failed for $name ($ip)"; continue; }

  done
  exec 3<&-

  success "Root CA installed on all nodes; ACME account configured; certificates ordered per node."
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
  sshRun $REMOTE_USER $PROXMOX_HOST 'bash /root/setup.sh destroy || true'
  sshRun $REMOTE_USER $PROXMOX_HOST 'pvesh set /nodes/pve/dns -dns1 1.1.1.1 -search domain.local'
  sshRun $REMOTE_USER $PROXMOX_HOST 'rm /usr/local/share/ca-certificates/proxmox-lab*.crt || true && update-ca-certificates -v'
  sshRun $REMOTE_USER $PROXMOX_HOST 'pvenode acme account deactivate default > /dev/null &2>1 || true'
  sshRun $REMOTE_USER $PROXMOX_HOST 'rm /etc/pve/priv/acme/default > /dev/null &2>1 || true'
  rm -r packer/packer-outputs
  rm -r terraform/lxc-step-ca/step-ca
  rm hosts.json
  rm proxmox-lab-root-ca.crt
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
  setupDockerSwarm
}

function runEverythingButSSH() {
  checkRequirements
  checkProxmox
  proxmoxPostInstall
  proxmoxLabInstall
  deployServices
  updateDNSRecords
  updateRootCertificates
  setupDockerSwarm
}

header
options=("New installation" "Rerun everything but SSH key gen" "Rebuild Pihole Template" "Rerun deploy services" "Deploy Docker Swarm" "Build DNS records" "Update Root Certificates" "Destroy lab" "Exit")
select opt in "${options[@]}"; do
  case $REPLY in
    1) runEverything;;
    2) runEverythingButSSH;;
    3) createPiholeTemplate;; 
    4) deployServices;;
    5) setupDockerSwarm;;
    6) updateDNSRecords;;
    7) updateRootCertificates;;
    8) destroyLab;;
    9|q|Q) warn "Exiting..."; break;;
    *) error "Invalid option";;
  esac
done
