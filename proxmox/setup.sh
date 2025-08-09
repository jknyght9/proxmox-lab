#!/bin/bash

set -euo pipefail
export TERM=xterm

# Do not change these values
SDN_ZONE_NAME="labzone"
SDN_VNET_NAME="labnet"
SDN_SUBNET="172.16.0.1/24"
SDN_SUBNET_CIDR="24"
SDN_GATEWAY="172.16.0.1"
SDN_SUBNET_PREFIX="lab.lan"
VM_TEMP_IMAGES='[
  {"name": "ubuntu-server-24.04", "url": "https://cloud-images.ubuntu.com/noble/20250704/noble-server-cloudimg-amd64.img", "vmid": 9999},
  {"name": "fedora-cloud-42", "url": "https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2", "vmid": 9998},
  {"name": "debian-12", "url": "https://cloud.debian.org/images/cloud/bookworm/20250703-2162/debian-12-genericcloud-amd64-20250703-2162.qcow2", "vmid": 9997}
]'
LXC_TEMP_IMAGES='[
  {"name": "debian-12-standard_12.7-1_amd64.tar.zst"}
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
  echo -e "[✓] Done\n"
}

function chooseStorage() {
  mapfile -t STORES < <(pvesh get /storage --output-format json | jq -r '.[] | select(.content | contains("images")) | .storage')

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
  echo "[+] Creating Proxmox SDN Zone: $SDN_ZONE_NAME"
  pvesh create /cluster/sdn/zones \
    -zone "$SDN_ZONE_NAME" \
    -type simple \
    -ipam pve || true

  echo "[+] Creating Proxmox VNet: $SDN_VNET_NAME"
  pvesh create /cluster/sdn/vnets \
    -vnet "$SDN_VNET_NAME" \
    -zone "$SDN_ZONE_NAME" \
    -alias "Lab Network" || true

  echo "[+] Creating Proxmox Subnet"
  cat > /etc/pve/sdn/subnets.cfg << EOF
subnet: $SDN_ZONE_NAME-$SDN_GATEWAY-$SDN_SUBNET_CIDR
        vnet $SDN_VNET_NAME
        dnszoneprefix $SDN_SUBNET_PREFIX
        gateway $SDN_GATEWAY
        snat 1
EOF

  pvesh set /cluster/sdn
  echo -e "[✓] SDN creation done\n"
}

function deployLXCImages() {
  for row in $(echo "$LXC_TEMP_IMAGES" | jq -c '.[]'); do 
    NAME=$(echo "$row" | jq -r '.name')
    installDebianLXCImage $NAME
  done
  echo -e "[✓] LXC deployment done\n"
}

function installDebianLXCImage() {
  STORAGE="local"
  TEMPLATE="$1"
  
  echo "[+] Downloading $TEMPLATE LXC container"
  if pveam list $STORAGE | grep -q "$TEMPLATE"; then
    echo "[!] Template already exists!"
  else 
    echo "[>] Downloading template..."
    pveam update > /dev/null 2>&1
    pveam download $STORAGE "$TEMPLATE" > /dev/null 2>&1

    if pveam list $STORAGE | grep -q "$TEMPLATE"; then
      echo "[!] Download complete!"
    else
      echo "[X] Download failed or template not found."
      exit 1
    fi
  fi
}

function deployCloudImages() {
  installCloudInitUserdata

  for row in $(echo "$VM_TEMP_IMAGES" | jq -c '.[]'); do 
    NAME=$(echo "$row" | jq -r '.name')
    URL=$(echo "$row" | jq -r '.url')
    VMID=$(echo "$row" | jq -r '.vmid')
    installCloudInitImage $NAME $URL $VMID
  done
  echo -e "[✓] Done\n"
}

function installCloudInitUserdata() {
  echo "[+] Installing userdata snippets for cloud-init"
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
  IMG_URL=$2
  IMG_NAME=$1
  VMID=$3

  echo "[+] Creating $IMG_NAME cloud-init image"
  wget -O "${IMG_NAME}.img" "$IMG_URL"
  mv "${IMG_NAME}.img" "${IMG_NAME}.qcow2"
  qemu-img resize "${IMG_NAME}.qcow2" 32G
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
  qm importdisk $VMID "${IMG_NAME}.qcow2" "$STORE" --format qcow2
  qm set $VMID --scsi0 "$STORE:vm-${VMID}-disk-0"
  qm set $VMID --boot order=scsi0
  qm set $VMID --ide2 "$STORE:cloudinit"
  qm set $VMID \
    --ciuser labadmin \
    --cipassword changeme123 \
    --ipconfig0 ip=dhcp \
    --sshkey /root/.ssh/lab-deploy.pub \
    --cicustom "vendor=local:snippets/userdata-qemu-agent.yaml"
  qm set $VMID --tags "template,linux,vm"
  qm template $VMID
}

function destroyLab() {
  echo "[-] Deleting SDN..."
  rm /etc/pve/sdn/subnets.cfg
  touch /etc/pve/sdn/subnets.cfg
  pvesh delete /cluster/sdn/vnets/$SDN_VNET_NAME
  pvesh delete /cluster/sdn/zones/$SDN_ZONE_NAME
  pvesh set /cluster/sdn

  echo "[-] Deleting VM templates..."
  find /root -iname "*.qcow2" -delete
  for row in $(echo "$VM_TEMP_IMAGES" | jq -c '.[]'); do 
    VMID=$(echo "$row" | jq -r '.vmid')
    qm destroy $VMID
  done

  echo "[-] Deleting LXC templates..."
  for row in $(echo $LXC_TEMP_IMAGES | jq -c '.[]'); do 
    NAME=$(echo "$row" | jq -r '.name')
    find /var/lib/vz/template/cache -iname "$NAME" -delete
  done 

  echo "[-] Deleting userdata..."
  find /var/lib/vz/snippets -iname "*.yaml" -delete
  echo -e "[✓] Done\n"
}

header
if [[ "${1:-}" == "destroy" ]]; then 
  echo "[-] Destroying the lab..."
  destroyLab
  exit 0
fi 

BRIDGE_INTERFACE=$(chooseBridge)
BRIDGE_NAME="${BRIDGE_INTERFACE%%:*}"
BRIDGE_IP="${BRIDGE_INTERFACE##*:}"
STORE=$(chooseStorage)

installRequirements
createLabSDN $BRIDGE_NAME $BRIDGE_IP
deployLXCImages
deployCloudImages