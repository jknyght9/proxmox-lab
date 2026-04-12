# =============================================================================
# Base Ubuntu Template Builder
# =============================================================================
#
# Creates VM template 9999 (Ubuntu 24.04 cloud image) on Proxmox via SSH.
# Uses a null source with shell-local provisioners since qm importdisk
# has no REST API equivalent.
#
# Usage:
#   docker compose run packer init .
#   docker compose run packer build build_base_ubuntu.pkr.hcl
#
# Prerequisites:
#   - SSH access to Proxmox node via /crypto/labenterpriseadmin key
#   - API token created (for future Packer builds that clone this template)
# =============================================================================

variable "ssh_enterprise_key_file" {
  type        = string
  description = "Path to enterprise private key for Proxmox node SSH"
  default     = "/crypto/labenterpriseadmin"
}

variable "base_template_vmid" {
  type        = number
  description = "VM ID for the base Ubuntu template"
  default     = 9999
}

variable "network_gateway" {
  type        = string
  description = "Network gateway (used for temporary static IP during base template agent install)"
  default     = ""
}

variable "network_cidr_mask" {
  type        = string
  description = "CIDR mask bits (e.g., 24)"
  default     = "24"
}

variable "ubuntu_image_url" {
  type        = string
  description = "URL for Ubuntu cloud image"
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

source "null" "ubuntu-base" {
  communicator = "none"
}

build {
  name    = "base-ubuntu"
  sources = ["source.null.ubuntu-base"]

  # Download Ubuntu 24.04 cloud image locally
  provisioner "shell-local" {
    inline = [
      "echo '[+] Downloading Ubuntu 24.04 cloud image...'",
      "if [ -f /tmp/noble-server-cloudimg-amd64.img ]; then",
      "  echo '    Image already downloaded, skipping'",
      "else",
      "  curl -L -o /tmp/noble-server-cloudimg-amd64.img '${var.ubuntu_image_url}'",
      "fi",
      "ls -lh /tmp/noble-server-cloudimg-amd64.img"
    ]
  }

  # Upload image to Proxmox node
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_URL=${var.proxmox_url}",
      "SSH_KEY=${var.ssh_enterprise_key_file}"
    ]
    inline = [
      "echo '[+] Uploading cloud image to Proxmox node...'",
      "PROXMOX_HOST=$(echo \"$PROXMOX_URL\" | sed -E 's|^https?://||; s|[:/].*$||')",
      "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY /tmp/noble-server-cloudimg-amd64.img root@$PROXMOX_HOST:/tmp/noble-server-cloudimg-amd64.img"
    ]
  }

  # Create the template on Proxmox via SSH + qm commands
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_URL=${var.proxmox_url}",
      "SSH_KEY=${var.ssh_enterprise_key_file}"
    ]
    inline = [
      <<-SCRIPT
      set -euo pipefail

      PROXMOX_HOST=$(echo "$PROXMOX_URL" | sed -E 's|^https?://||; s|[:/].*$||')
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -i $SSH_KEY"

      echo "[+] Creating base Ubuntu template on Proxmox..."
      ssh $SSH_OPTS root@$PROXMOX_HOST bash -s -- \
        "${var.base_template_vmid}" \
        "${var.template_storage}" \
        "${var.template_storage_type}" \
        "${var.network_bridge}" \
        "${var.ssh_username}" \
        "${var.ssh_password}" \
        <<'REMOTE_SCRIPT'
      set -euo pipefail

      VMID="$1"
      STORAGE="$2"
      STORAGE_TYPE="$3"
      BRIDGE="$4"
      SSH_USER="$5"
      SSH_PASS="$6"
      IMAGE="/tmp/noble-server-cloudimg-amd64.img"

      echo "[+] Checking for existing VM $VMID..."
      if qm status "$VMID" >/dev/null 2>&1; then
        echo "    Destroying existing VM $VMID..."
        qm stop "$VMID" --skiplock true 2>/dev/null || true
        qm destroy "$VMID" --purge true --destroy-unreferenced-disks true
      fi

      echo "[+] Creating VM $VMID..."
      qm create "$VMID" \
        --name "ubuntu-base-template" \
        --cores 2 \
        --memory 2048 \
        --agent enabled=1 \
        --scsihw virtio-scsi-pci \
        --net0 "virtio,bridge=$BRIDGE"

      echo "[+] Importing disk to storage $STORAGE..."
      qm importdisk "$VMID" "$IMAGE" "$STORAGE"

      # Determine the disk path based on storage type
      case "$STORAGE_TYPE" in
        nfs|dir|cifs)
          DISK_REF="$STORAGE:$VMID/vm-$VMID-disk-0.raw"
          ;;
        *)
          DISK_REF="$STORAGE:vm-$VMID-disk-0"
          ;;
      esac

      echo "[+] Attaching disk as scsi0 ($DISK_REF)..."
      qm set "$VMID" --scsi0 "$DISK_REF"

      echo "[+] Resizing disk to 32G..."
      qm disk resize "$VMID" scsi0 32G

      echo "[+] Configuring boot order..."
      qm set "$VMID" --boot order=scsi0

      echo "[+] Adding cloud-init drive on ide2..."
      qm set "$VMID" --ide2 "$STORAGE:cloudinit"

      echo "[+] Configuring cloud-init defaults..."
      qm set "$VMID" \
        --ciuser "$SSH_USER" \
        --cipassword "$SSH_PASS" \
        --ipconfig0 "ip=dhcp" \
        --serial0 socket \
        --vga serial0

      echo "[+] Cleaning up image..."
      rm -f "$IMAGE"

      echo "[+] VM $VMID configured (not yet templated — agent install pending)"
      REMOTE_SCRIPT
      SCRIPT
    ]
  }

  # Inject SSH public key via cloud-init (before first boot)
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_URL=${var.proxmox_url}",
      "VMID=${var.base_template_vmid}",
      "SSH_KEY=${var.ssh_enterprise_key_file}",
      "SSH_PUBKEY=${var.ssh_public_key_file}"
    ]
    inline = [
      <<-SCRIPT
      set -euo pipefail

      PROXMOX_HOST=$(echo "$PROXMOX_URL" | sed -E 's|^https?://||; s|[:/].*$||')
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -i $SSH_KEY"

      if [ -f "$SSH_PUBKEY" ]; then
        echo "[+] Injecting SSH public key into cloud-init..."
        scp $SSH_OPTS "$SSH_PUBKEY" root@$PROXMOX_HOST:/tmp/template-sshkey.pub
        ssh $SSH_OPTS root@$PROXMOX_HOST "qm set $VMID --sshkeys /tmp/template-sshkey.pub && rm -f /tmp/template-sshkey.pub"
        echo "[+] SSH public key injected"
      else
        echo "[!] SSH public key not found at $SSH_PUBKEY - skipping cloud-init SSH key"
      fi
      SCRIPT
    ]
  }

  # Boot VM with a temporary static IP, install qemu-guest-agent
  # (required by Packer proxmox-clone builder to discover VM IP),
  # then revert to DHCP and convert to template.
  #
  # We use a .254 address on the Proxmox host's bridge subnet to avoid
  # conflicts with DHCP ranges or allocated services.
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_URL=${var.proxmox_url}",
      "VMID=${var.base_template_vmid}",
      "SSH_KEY=${var.ssh_enterprise_key_file}",
      "SSH_USER=${var.ssh_username}",
      "SSH_PASS=${var.ssh_password}",
      "NETWORK_GW=${var.network_gateway}",
      "NETWORK_CIDR=${var.network_cidr_mask}"
    ]
    inline = [
      <<-SCRIPT
      set -euo pipefail

      PROXMOX_HOST=$(echo "$PROXMOX_URL" | sed -E 's|^https?://||; s|[:/].*$||')
      PVE_SSH="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -i $SSH_KEY"

      if [ -z "$NETWORK_GW" ]; then
        echo "[!] network_gateway not set — skipping guest agent install"
        echo "[!] WARNING: Packer proxmox-clone builds may timeout waiting for SSH."
        ssh $PVE_SSH root@$PROXMOX_HOST "qm template $VMID"
        exit 0
      fi

      # Derive temp IP from gateway (replace last octet with .254)
      TEMP_IP=$(echo "$NETWORK_GW" | sed 's/\.[0-9]*$/.254/')
      echo "[+] Temp IP: $TEMP_IP/$NETWORK_CIDR, Gateway: $NETWORK_GW"

      # Set temporary static IP and boot
      echo "[+] Setting temporary static IP and starting VM..."
      ssh $PVE_SSH root@$PROXMOX_HOST \
        "qm set $VMID --ipconfig0 ip=$TEMP_IP/$NETWORK_CIDR,gw=$NETWORK_GW && qm start $VMID"

      # Wait for SSH to become available (cloud-init takes ~30-60s)
      # SSH directly from container — Docker Desktop NATs outbound to the VM subnet
      VM_SSH="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i /crypto/labadmin"
      echo "[+] Waiting for SSH on $TEMP_IP..."
      for i in $(seq 1 40); do
        if ssh $VM_SSH $SSH_USER@$TEMP_IP 'echo OK' 2>/dev/null | grep -q OK; then
          echo "    SSH available on $TEMP_IP"
          break
        fi
        printf "    Waiting... (%d/40)\r" "$i"
        sleep 5
      done

      echo "[+] Waiting for cloud-init to finish..."
      ssh $VM_SSH $SSH_USER@$TEMP_IP 'cloud-init status --wait' 2>/dev/null || true

      echo "[+] Installing qemu-guest-agent..."
      ssh $VM_SSH $SSH_USER@$TEMP_IP \
        'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-guest-agent && sudo systemctl enable qemu-guest-agent && sudo systemctl start qemu-guest-agent && echo AGENT_OK'

      # Revert to DHCP and clean up
      echo "[+] Reverting cloud-init to DHCP..."
      ssh $PVE_SSH root@$PROXMOX_HOST "qm shutdown $VMID --timeout 30 2>/dev/null || qm stop $VMID"
      sleep 5
      ssh $PVE_SSH root@$PROXMOX_HOST "qm set $VMID --ipconfig0 ip=dhcp"

      echo "[+] Converting to template..."
      ssh $PVE_SSH root@$PROXMOX_HOST "qm template $VMID"

      echo "[+] Base Ubuntu template $VMID created successfully (with guest agent)"
      SCRIPT
    ]
  }
}
