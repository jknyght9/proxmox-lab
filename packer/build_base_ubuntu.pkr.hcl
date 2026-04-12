# =============================================================================
# Base Ubuntu Template Builder
# =============================================================================
#
# Creates VM template 9999 (Ubuntu 24.04 cloud image) on Proxmox via SSH.
# Uses a null source with shell-local provisioners since qm importdisk
# has no REST API equivalent.
#
# Cloud-init vendor data installs qemu-guest-agent on first boot so the
# Packer proxmox-clone builder can discover the VM's IP via the guest agent.
#
# Usage:
#   docker compose run packer build -only='base-ubuntu.*' .
#
# Prerequisites:
#   - SSH access to Proxmox node via /crypto/labenterpriseadmin key
#   - API token created (for future Packer builds that clone this template)
#   - Shared storage with 'snippets' content type (for cloud-init vendor data)
# =============================================================================

// Variables are defined in variables.pkr.hcl:
//   ssh_enterprise_key_file, snippet_storage,
//   base_ubuntu_vmid, ubuntu_image_url

source "null" "ubuntu-base" {
  communicator = "none"
}

build {
  name    = "base-ubuntu"
  sources = ["source.null.ubuntu-base"]

  # Upload cloud-init vendor snippet to shared storage.
  # This installs qemu-guest-agent on first boot of any clone.
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_URL=${var.proxmox_url}",
      "SSH_KEY=${var.ssh_enterprise_key_file}",
      "SNIPPET_STORAGE=${var.snippet_storage}"
    ]
    inline = [
      <<-SCRIPT
      set -euo pipefail

      PROXMOX_HOST=$(echo "$PROXMOX_URL" | sed -E 's|^https?://||; s|[:/].*$||')
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -i $SSH_KEY"

      echo "[+] Uploading cloud-init vendor snippet to $SNIPPET_STORAGE..."

      # Get the filesystem path for the snippet storage
      SNIPPET_PATH=$(ssh $SSH_OPTS root@$PROXMOX_HOST \
        "pvesm path $SNIPPET_STORAGE:snippets/cloud-init-agent.yaml 2>/dev/null | sed 's|/cloud-init-agent.yaml$||'" 2>/dev/null || echo "")

      if [ -z "$SNIPPET_PATH" ]; then
        # Fallback: common snippet paths
        SNIPPET_PATH=$(ssh $SSH_OPTS root@$PROXMOX_HOST \
          "cat /etc/pve/storage.cfg | awk '/^[a-z]+ *: *'$SNIPPET_STORAGE'/{found=1} found && /path/{print \$2; exit}'")
        SNIPPET_PATH="$SNIPPET_PATH/snippets"
      fi

      echo "    Snippet path: $SNIPPET_PATH"

      ssh $SSH_OPTS root@$PROXMOX_HOST "mkdir -p '$SNIPPET_PATH' && cat > '$SNIPPET_PATH/cloud-init-agent.yaml'" <<'CLOUD_INIT'
#cloud-config
# Enable password auth so Packer can SSH before pubkey is fully provisioned
# (guest agent starts before cloud-init finishes writing authorized_keys)
ssh_pwauth: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
CLOUD_INIT

      echo "[+] Cloud-init vendor snippet uploaded"
      SCRIPT
    ]
  }

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
        "${var.base_ubuntu_vmid}" \
        "${var.template_storage}" \
        "${var.template_storage_type}" \
        "${var.network_bridge}" \
        "${var.ssh_username}" \
        "${var.ssh_password}" \
        "${var.snippet_storage}" \
        <<'REMOTE_SCRIPT'
      set -euo pipefail

      VMID="$1"
      STORAGE="$2"
      STORAGE_TYPE="$3"
      BRIDGE="$4"
      SSH_USER="$5"
      SSH_PASS="$6"
      SNIPPET_STORE="$7"
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

      echo "[+] Attaching cloud-init vendor data (installs qemu-guest-agent on boot)..."
      qm set "$VMID" --cicustom "vendor=$SNIPPET_STORE:snippets/cloud-init-agent.yaml"

      echo "[+] Cleaning up image..."
      rm -f "$IMAGE"

      echo "[+] Converting to template..."
      qm template "$VMID"

      echo "[+] Base Ubuntu template $VMID created successfully"
      REMOTE_SCRIPT
      SCRIPT
    ]
  }

  # Inject SSH public key via cloud-init
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_URL=${var.proxmox_url}",
      "VMID=${var.base_ubuntu_vmid}",
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
}
