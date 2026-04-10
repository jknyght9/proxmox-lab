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
      "PROXMOX_HOST=${regex("https?://([^:/]+)", var.proxmox_url)[0]}",
      "SSH_KEY=${var.ssh_enterprise_key_file}"
    ]
    inline = [
      "echo '[+] Uploading cloud image to Proxmox node...'",
      "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY /tmp/noble-server-cloudimg-amd64.img root@$PROXMOX_HOST:/tmp/noble-server-cloudimg-amd64.img"
    ]
  }

  # Create the template on Proxmox via SSH + qm commands
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_HOST=${regex("https?://([^:/]+)", var.proxmox_url)[0]}",
      "SSH_KEY=${var.ssh_enterprise_key_file}"
    ]
    inline = [
      <<-SCRIPT
      set -euo pipefail

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

      echo "[+] Converting to template..."
      qm template "$VMID"

      echo "[+] Cleaning up image..."
      rm -f "$IMAGE"

      echo "[+] Base Ubuntu template $VMID created successfully"
      REMOTE_SCRIPT
      SCRIPT
    ]
  }

  # Inject SSH public key via cloud-init (separate step — needs local file read)
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_HOST=${regex("https?://([^:/]+)", var.proxmox_url)[0]}",
      "VMID=${var.base_template_vmid}",
      "SSH_KEY=${var.ssh_enterprise_key_file}",
      "SSH_PUBKEY=${var.ssh_public_key_file}"
    ]
    inline = [
      <<-SCRIPT
      set -euo pipefail

      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -i $SSH_KEY"

      if [ -f "$SSH_PUBKEY" ]; then
        echo "[+] Injecting SSH public key into cloud-init..."
        # URL-encode the public key for qm set --sshkeys
        PUBKEY_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))" < "$SSH_PUBKEY" 2>/dev/null || cat "$SSH_PUBKEY")
        # Upload key file to Proxmox, set it, then clean up
        scp $SSH_OPTS "$SSH_PUBKEY" root@$PROXMOX_HOST:/tmp/template-sshkey.pub
        ssh $SSH_OPTS root@$PROXMOX_HOST "qm set $VMID --sshkeys /tmp/template-sshkey.pub && rm -f /tmp/template-sshkey.pub"
        echo "[+] SSH public key injected"
      else
        echo "[!] SSH public key not found at $SSH_PUBKEY - skipping cloud-init SSH key"
      fi
      SCRIPT
    ]
  }
}
