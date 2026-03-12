#!/bin/bash

set -euo pipefail
export TERM=xterm

# Mode and configuration
MODE="${1:-full}"
CONFIG_JSON="${2:-}"

# SDN defaults (can be overridden by config JSON)
SDN_ZONE_NAME="labzone"
SDN_VNET_NAME="labnet"
SDN_SUBNET_CIDR="24"
SDN_GATEWAY="172.16.0.1"
SDN_SUBNET="172.16.0.0/24"
SDN_SUBNET_PREFIX="lab.lan"

# Global variables set during interactive mode (or from config JSON)
BRIDGE_NAME=""
BRIDGE_IP=""
STORE=""
SDN_EGRESS_BRIDGE=""
SDN_EGRESS_IP=""

# Ensure jq is installed before parsing config (needed for JSON parsing)
if ! command -v jq &>/dev/null; then
  echo "[+] Installing jq (required for config parsing)..."
  apt-get update -qq && apt-get install -y -qq jq
fi

# Parse config from JSON if provided
if [ -n "$CONFIG_JSON" ]; then
  # Extract storage and bridge config
  STORE=$(echo "$CONFIG_JSON" | jq -r '.storage.selected // ""')
  BRIDGE_NAME=$(echo "$CONFIG_JSON" | jq -r '.network.selected_bridge // ""')

  # Extract labnet/SDN config
  INT_CIDR=$(echo "$CONFIG_JSON" | jq -r '.network.labnet.cidr // "172.16.0.0/24"')
  INT_GW=$(echo "$CONFIG_JSON" | jq -r '.network.labnet.gateway // "172.16.0.1"')
  DNS_POSTFIX=$(echo "$CONFIG_JSON" | jq -r '.dns_postfix // "lab.lan"')
  LABNET_ENABLED=$(echo "$CONFIG_JSON" | jq -r '.network.labnet.enabled // true')

  # Extract template password (for cloud-init VMs)
  TEMPLATE_PASSWORD=$(echo "$CONFIG_JSON" | jq -r '.template_password // ""')

  if [ "$LABNET_ENABLED" = "true" ]; then
    SDN_GATEWAY="$INT_GW"
    SDN_SUBNET="$INT_CIDR"
    SDN_SUBNET_CIDR=$(echo "$INT_CIDR" | grep -oE '[0-9]+$')
    SDN_SUBNET_PREFIX="$DNS_POSTFIX"
    # Egress configuration for SNAT (which interface/IP to use for outbound traffic)
    SDN_EGRESS_BRIDGE=$(echo "$CONFIG_JSON" | jq -r '.network.labnet.egress_bridge // ""')
    SDN_EGRESS_IP=$(echo "$CONFIG_JSON" | jq -r '.network.labnet.egress_ip // ""')
  fi

  echo "[+] Config loaded: storage=$STORE, bridge=$BRIDGE_NAME"
fi

# Cloud image URLs - use /current/ or /latest/ symlinks to avoid hardcoded dates breaking
VM_TEMP_IMAGES='[
  {"name": "ubuntu-server-24.04", "url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img", "vmid": 9999},
  {"name": "fedora-cloud-42", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2", "vmid": 9998},
  {"name": "debian-12", "url": "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2", "vmid": 9997}
]'
LXC_TEMP_IMAGES='[
  {"name": "debian-12-standard"}
]'

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

function installRequirements() {
  echo "[+] Installing requirements..."
  apt-get update && apt-get install -y jq
  echo -e "[+] Done\n"
}

function chooseStorage() {
  mapfile -t STORES < <(pvesh get /storage --output-format json | jq -r '.[] | select(.content | contains("images")) | .storage' | sort)

  if [[ ${#STORES[@]} -eq 0 ]]; then
    whiptail --title "Storage selection" --msgbox "No stores found!" 8 40
    exit 1
  fi

  OPTIONS=()
  for entry in "${STORES[@]}"; do
    OPTIONS+=("$entry" "")
  done

  SELECTED_STORE=$(whiptail --title "Select store" \
    --menu "Choose a storage device:" 20 70 10 \
    "${OPTIONS[@]}" \
    3>&1 1>&2 2>&3)

  exitstatus=$?
  if [[ $exitstatus -ne 0 ]]; then
    echo "[X] User cancelled selection."
    exit 1
  fi

  echo "$SELECTED_STORE"
}

function chooseBridge() {
  mapfile -t BRIDGES < <(ip -br addr show | grep -E '^vmbr|^br' | awk '{print $1, $3}')

  if [[ ${#BRIDGES[@]} -eq 0 ]]; then
    whiptail --title "Bridge Interface Selection" --msgbox "No bridge interfaces found!" 8 40
    exit 1
  fi

  OPTIONS=()
  for entry in "${BRIDGES[@]}"; do
    iface=$(awk '{print $1}' <<< "$entry")
    ipaddr=$(awk '{print $2}' <<< "$entry")
    ipaddr=${ipaddr:-"No IP"}
    OPTIONS+=("$iface" "$ipaddr")
  done

  SELECTED_BRIDGE=$(whiptail --title "Select Bridge Interface" \
    --menu "Choose a bridge interface to route traffic:" 20 70 10 \
    "${OPTIONS[@]}" \
    3>&1 1>&2 2>&3)

  exitstatus=$?
  if [[ $exitstatus -ne 0 ]]; then
    echo "[X] User cancelled selection."
    exit 1
  fi

  SELECTED_IP=$(ip -br addr show "$SELECTED_BRIDGE" | awk '{split($3,a,"/"); print a[1]}')
  echo "$SELECTED_BRIDGE:$SELECTED_IP"
}

function createLabSDN() {
  # Skip if labnet is disabled
  if [ -n "$CONFIG_JSON" ]; then
    local enabled=$(echo "$CONFIG_JSON" | jq -r '.network.labnet.enabled // true')
    if [ "$enabled" = "false" ]; then
      echo "[!] SDN labnet disabled in config, skipping"
      return 0
    fi
  fi

  local ZONE_EXISTS=false
  local VNET_EXISTS=false
  local SUBNET_EXISTS=false

  # Check if zone exists
  if pvesh get /cluster/sdn/zones --output-format json 2>/dev/null | jq -e ".[] | select(.zone == \"$SDN_ZONE_NAME\")" > /dev/null 2>&1; then
    ZONE_EXISTS=true
  fi

  # Check if vnet exists
  if pvesh get /cluster/sdn/vnets --output-format json 2>/dev/null | jq -e ".[] | select(.vnet == \"$SDN_VNET_NAME\")" > /dev/null 2>&1; then
    VNET_EXISTS=true
  fi

  # Check if subnet config exists
  if [[ -f /etc/pve/sdn/subnets.cfg ]] && grep -q "subnet: $SDN_ZONE_NAME-$SDN_GATEWAY-$SDN_SUBNET_CIDR" /etc/pve/sdn/subnets.cfg 2>/dev/null; then
    SUBNET_EXISTS=true
  fi

  # If all exist, skip entirely
  if $ZONE_EXISTS && $VNET_EXISTS && $SUBNET_EXISTS; then
    echo "[+] SDN already configured (zone: $SDN_ZONE_NAME, vnet: $SDN_VNET_NAME), skipping"
    return 0
  fi

  echo "[+] Creating Proxmox SDN Zone: $SDN_ZONE_NAME"
  if $ZONE_EXISTS; then
    echo "    - zone exists"
  else
    pvesh create /cluster/sdn/zones \
      -zone "$SDN_ZONE_NAME" \
      -type simple \
      -ipam pve
    echo "    - created"
  fi

  echo "[+] Creating Proxmox VNet: $SDN_VNET_NAME"
  if $VNET_EXISTS; then
    echo "    - vnet exists"
  else
    pvesh create /cluster/sdn/vnets \
      -vnet "$SDN_VNET_NAME" \
      -zone "$SDN_ZONE_NAME" \
      -alias "Lab Network"
    echo "    - created"
  fi

  echo "[+] Creating Proxmox Subnet: $SDN_SUBNET (gateway: $SDN_GATEWAY)"
  if $SUBNET_EXISTS; then
    echo "    - subnet exists"
  else
    # Use pvesh API to create subnet properly (ensures proper rule generation)
    pvesh create /cluster/sdn/vnets/${SDN_VNET_NAME}/subnets \
      -subnet "$SDN_SUBNET" \
      -gateway "$SDN_GATEWAY" \
      -snat 1 \
      -type subnet 2>/dev/null || {
      # Fallback to direct file write if API fails (older Proxmox versions)
      echo "    - API create failed, using config file"
      cat >> /etc/pve/sdn/subnets.cfg << EOF
subnet: $SDN_ZONE_NAME-$SDN_GATEWAY-$SDN_SUBNET_CIDR
        vnet $SDN_VNET_NAME
        dnszoneprefix $SDN_SUBNET_PREFIX
        gateway $SDN_GATEWAY
        snat 1
EOF
    }
    echo "    - created"
  fi

  # Enable IP forwarding (required for SNAT)
  echo "[+] Enabling IP forwarding for SNAT..."
  sysctl -w net.ipv4.ip_forward=1
  if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi

  # Apply SDN configuration (generates firewall/routing rules)
  echo "[+] Applying SDN configuration..."
  pvesh set /cluster/sdn

  # Verify and configure SNAT rules
  echo "[+] Configuring NAT rules..."

  # Remove any existing SNAT/MASQUERADE rules for this subnet to avoid duplicates
  iptables -t nat -S POSTROUTING 2>/dev/null | grep -E "(-s ${SDN_SUBNET}.*MASQUERADE|-s ${SDN_SUBNET}.*SNAT)" | while read -r rule; do
    # Convert -A to -D for deletion
    delete_rule=$(echo "$rule" | sed 's/^-A/-D/')
    iptables -t nat $delete_rule 2>/dev/null || true
  done

  # Add SNAT rule with explicit egress interface/IP if configured
  if [ -n "$SDN_EGRESS_IP" ] && [ -n "$SDN_EGRESS_BRIDGE" ]; then
    echo "    - Using SNAT via $SDN_EGRESS_BRIDGE ($SDN_EGRESS_IP)"
    iptables -t nat -A POSTROUTING -s ${SDN_SUBNET} ! -d ${SDN_SUBNET} -o ${SDN_EGRESS_BRIDGE} -j SNAT --to-source ${SDN_EGRESS_IP}
  else
    echo "    - Using MASQUERADE (default route)"
    iptables -t nat -A POSTROUTING -s ${SDN_SUBNET} ! -d ${SDN_SUBNET} -j MASQUERADE
  fi

  # Make iptables rules persistent
  if command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    echo "    - NAT rules saved"
  fi

  echo -e "[+] SDN creation done\n"
}

function deployLXCImages() {
  echo "[+] Deploying LXC templates..."
  for row in $(echo "$LXC_TEMP_IMAGES" | jq -c '.[]'); do
    NAME=$(echo "$row" | jq -r '.name')
    installDebianLXCImage $NAME
  done
  echo -e "[+] LXC deployment done\n"
}

function installDebianLXCImage() {
  STORAGE="local"
  TEMPLATE="$1"

  echo "[+] Downloading $TEMPLATE LXC container"
  if pveam list $STORAGE | grep -q "$TEMPLATE"; then
    echo "    - Template already exists!"
  else
    echo "    - Downloading template..."
    pveam update > /dev/null 2>&1
    DEBIAN_LXC=$(pveam available | grep debian-12-standard | awk '{print $2}')
    pveam download $STORAGE "$DEBIAN_LXC" > /dev/null 2>&1

    if pveam list $STORAGE | grep -q "$DEBIAN_LXC"; then
      echo "    - Download complete!"
    else
      echo "[X] Download failed or template not found."
      exit 1
    fi
  fi
}

function deployCloudImages() {
  echo "[+] Deploying cloud-init VM templates..."

  # Ensure we have storage and bridge set (from config or prompt)
  if [ -z "$STORE" ]; then
    STORE=$(chooseStorage)
  else
    echo "    - Using storage: $STORE (from config)"
  fi
  if [ -z "$BRIDGE_NAME" ]; then
    local BRIDGE_INTERFACE=$(chooseBridge)
    BRIDGE_NAME="${BRIDGE_INTERFACE%%:*}"
    BRIDGE_IP="${BRIDGE_INTERFACE##*:}"
  else
    echo "    - Using bridge: $BRIDGE_NAME (from config)"
  fi

  installCloudInitUserdata

  for row in $(echo "$VM_TEMP_IMAGES" | jq -c '.[]'); do
    NAME=$(echo "$row" | jq -r '.name')
    URL=$(echo "$row" | jq -r '.url')
    VMID=$(echo "$row" | jq -r '.vmid')
    installCloudInitImage $NAME $URL $VMID
  done
  echo -e "[+] Done\n"
}

function installCloudInitUserdata() {
  echo "[+] Installing userdata snippets for cloud-init"
  mkdir -p /var/lib/vz/snippets > /dev/null 2>&1
  cat << EOF > /var/lib/vz/snippets/userdata-qemu-agent.yaml
#cloud-config
ssh_pwauth: true
disable_root: false
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF
}

function installCloudInitImage() {
  IMG_NAME=$1
  IMG_URL=$2
  VMID=$3

  echo "[+] Creating $IMG_NAME cloud-init image (VMID: $VMID)"

  # Check if VM/template already exists cluster-wide
  # Use pvesh to check all cluster resources (more reliable than qm status)
  if pvesh get /cluster/resources --type vm 2>/dev/null | grep -q "\"vmid\":$VMID"; then
    echo "    - VM $VMID already exists in cluster, skipping"
    return 0
  fi

  # Also check locally in case cluster API is slow
  if qm status $VMID &>/dev/null; then
    echo "    - VM $VMID already exists locally, skipping"
    return 0
  fi

  echo "    - Downloading image..."
  wget -q --show-progress -O "${IMG_NAME}.img" "$IMG_URL"
  mv "${IMG_NAME}.img" "${IMG_NAME}.qcow2"
  qemu-img resize "${IMG_NAME}.qcow2" 32G

  echo "    - Creating VM..."
  qm create $VMID \
    --name "$IMG_NAME" \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=$BRIDGE_NAME \
    --serial0 socket \
    --vga qxl \
    --boot c \
    --ostype l26 \
    --agent enabled=1 \
    --scsihw virtio-scsi-pci
  # Import disk and capture the actual disk reference from output
  local IMPORT_OUTPUT=$(qm importdisk $VMID "${IMG_NAME}.qcow2" "$STORE" --format qcow2 2>&1)
  echo "$IMPORT_OUTPUT"

  # Parse the disk reference from: "unused0: successfully imported disk 'storage:path'"
  # Extract text between single quotes after "successfully imported disk"
  local DISK_REF=$(echo "$IMPORT_OUTPUT" | sed -n "s/.*successfully imported disk '\([^']*\)'.*/\1/p")

  if [ -z "$DISK_REF" ]; then
    echo "    - ERROR: Could not parse disk reference from import output"
    return 1
  fi

  qm set $VMID --scsi0 "$DISK_REF"
  qm set $VMID --boot order=scsi0
  qm set $VMID --ide2 "$STORE:cloudinit"
  # Use template password from config, or generate a random one
  local CI_PASSWORD="${TEMPLATE_PASSWORD:-$(openssl rand -base64 12)}"
  qm set $VMID \
    --ciuser labadmin \
    --cipassword "$CI_PASSWORD" \
    --ipconfig0 ip=dhcp \
    --sshkey /root/.ssh/lab-deploy.pub \
    --cicustom "vendor=local:snippets/userdata-qemu-agent.yaml"
  qm set $VMID --tags "template,linux,vm"
  qm template $VMID

  # Clean up downloaded image
  rm -f "${IMG_NAME}.qcow2"
  echo "    - Created successfully"
}

function createHashicorpUser() {
  local USER="hashicorp@pam"
  local ROLE="HashicorpBuild"
  local TOKEN_ID="hashicorp-token"
  local REGENERATE_TOKEN="${REGENERATE_TOKEN:-false}"

  has_user()   { pveum user list --output-format json 2>/dev/null | jq -e ".[] | select(.userid == \"$USER\")" > /dev/null 2>&1; }
  has_role()   { pveum role list --output-format json 2>/dev/null | jq -e ".[] | select(.roleid == \"$ROLE\")" > /dev/null 2>&1; }
  has_token()  { pveum user token list "$USER" --output-format json 2>/dev/null | jq -e ".[] | select(.tokenid == \"$TOKEN_ID\")" > /dev/null 2>&1; }
  has_acl_all(){ pveum acl list --output-format json 2>/dev/null | jq -e ".[] | select(.path == \"/\" and .ugid == \"$USER\" and .roleid == \"$ROLE\")" > /dev/null 2>&1; }

  echo "[*] Ensuring Proxmox user: $USER"
  if has_user; then
    echo "    - exists"
  else
    pveum user add "$USER" --enable 1 --comment "CI user for Packer/Terraform builds"
    echo "    - created"
  fi

  echo "[*] Ensuring minimal custom role: $ROLE"
  if has_role; then
    echo "    - exists"
  else
    pveum roleadd "$ROLE" -privs \
      "Sys.Audit,Sys.Console,Sys.Modify,Sys.PowerMgmt,SDN.Use,Pool.Allocate,Datastore.Audit,Datastore.Allocate,Datastore.AllocateTemplate,Datastore.AllocateSpace,VM.Allocate,VM.Audit,VM.Clone,VM.Migrate,VM.Config.CDROM,VM.Config.Cloudinit,VM.Config.CPU,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.PowerMgmt,VM.GuestAgent.Audit,VM.GuestAgent.Unrestricted,Permissions.Modify"
    echo "    - created"
  fi

  echo "[*] Granting ACL on Datacenter root '/'"
  if has_acl_all; then
    echo "    - ACL already present"
  else
    pveum aclmod / -user "$USER" -role "$ROLE"
    echo "    - ACL granted"
  fi

  echo "[*] Ensuring API token: ${USER}!${TOKEN_ID}"

  # Check if we should regenerate the token (for credential recovery)
  if [ "$REGENERATE_TOKEN" = "true" ] && has_token; then
    echo "    - regenerating token (deleting old one)..."
    pveum user token remove "$USER" "$TOKEN_ID" 2>/dev/null || true
  fi

  if has_token; then
    echo "    - token exists (secret cannot be retrieved; set REGENERATE_TOKEN=true to recreate)"
    # Output empty token info so caller knows token exists but secret unavailable
    echo "PROXMOX_TOKEN_INFO:${USER}!${TOKEN_ID}:EXISTING"
  else
    echo "    - creating new API token..."
    local TOKEN_OUTPUT
    TOKEN_OUTPUT=$(pveum user token add "$USER" "$TOKEN_ID" --privsep=0 --output-format json 2>/dev/null)

    if [ -n "$TOKEN_OUTPUT" ]; then
      local TOKEN_SECRET
      TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | jq -r '.value // empty')
      if [ -n "$TOKEN_SECRET" ]; then
        echo "    - token created successfully"
        # Output token info in a parseable format for the calling script
        echo "PROXMOX_TOKEN_INFO:${USER}!${TOKEN_ID}:${TOKEN_SECRET}"
      else
        echo "    - WARNING: token created but could not extract secret"
        echo "PROXMOX_TOKEN_INFO:${USER}!${TOKEN_ID}:UNKNOWN"
      fi
    else
      # Fallback for older Proxmox versions that don't support JSON output
      pveum user token add "$USER" "$TOKEN_ID" --privsep=0
      echo "    - token created (check output above for secret)"
      echo "PROXMOX_TOKEN_INFO:${USER}!${TOKEN_ID}:MANUAL"
    fi
  fi
  echo
}

function destroyLab() {
  echo "[-] Deleting SDN..."
  rm /etc/pve/sdn/subnets.cfg 2>/dev/null || true
  touch /etc/pve/sdn/subnets.cfg
  pvesh delete /cluster/sdn/vnets/$SDN_VNET_NAME 2>/dev/null || true
  pvesh delete /cluster/sdn/zones/$SDN_ZONE_NAME 2>/dev/null || true
  pvesh set /cluster/sdn

  echo "[-] Deleting VM templates..."
  find /root -iname "*.qcow2" -delete 2>/dev/null || true
  for row in $(echo "$VM_TEMP_IMAGES" | jq -c '.[]'); do
    VMID=$(echo "$row" | jq -r '.vmid')
    qm destroy $VMID 2>/dev/null || true
  done

  echo "[-] Deleting LXC templates..."
  for row in $(echo $LXC_TEMP_IMAGES | jq -c '.[]'); do
    NAME=$(echo "$row" | jq -r '.name')
    find /var/lib/vz/template/cache -iname "$NAME*" -delete 2>/dev/null || true
  done

  echo "[-] Deleting userdata..."
  find /var/lib/vz/snippets -iname "*.yaml" -delete 2>/dev/null || true

  echo "[-] Removing Hashicorp user and permissions..."
  pveum user delete hashicorp@pam 2>/dev/null || true
  pveum role delete HashicorpBuild 2>/dev/null || true

  echo -e "[+] Done\n"
}

# Main execution based on mode
case "$MODE" in
  cluster-init)
    # Cluster-wide operations (run ONCE on primary node)
    # Includes: SDN, user/permissions, cloud-init templates (cluster-unique VMIDs)
    echo "=========================================="
    echo "Proxmox Lab Setup - Cluster Initialization"
    echo "=========================================="
    echo
    installRequirements
    createLabSDN
    createHashicorpUser
    installCloudInitUserdata
    deployCloudImages  # Cloud-init templates are cluster-wide (unique VMIDs)
    echo "[+] Cluster initialization complete"
    ;;

  node-setup)
    # Per-node operations (run on EACH node)
    # Only LXC templates - stored in local storage, needed on each node
    echo "=========================================="
    echo "Proxmox Lab Setup - Node Configuration"
    echo "=========================================="
    echo
    installRequirements
    deployLXCImages  # LXC templates are per-node (local storage)
    echo "[+] Node setup complete"
    ;;

  destroy)
    echo "[-] Destroying the lab..."
    destroyLab
    ;;

  full|*)
    # Interactive full setup (backward compatible)
    header

    BRIDGE_INTERFACE=$(chooseBridge)
    BRIDGE_NAME="${BRIDGE_INTERFACE%%:*}"
    BRIDGE_IP="${BRIDGE_INTERFACE##*:}"

    installRequirements
    STORE=$(chooseStorage)
    createLabSDN
    deployLXCImages
    deployCloudImages
    createHashicorpUser

    echo
    echo "[+] Setup complete!"
    echo "    If you ran this through the main setup.sh, API credentials are auto-saved."
    echo "    If you ran this manually on Proxmox, note the token secret shown above"
    echo "    and update packer.auto.pkrvars.hcl and terraform.tfvars accordingly."
    echo
    ;;
esac
