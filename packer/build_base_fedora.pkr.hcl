# =============================================================================
# Base Fedora Template Builder
# =============================================================================
#
# Creates VM template 9998 (Fedora Cloud 42) on Proxmox via SSH.
# Same pattern as build_base_ubuntu.pkr.hcl — see that file for details.
#
# Usage:
#   docker compose run packer build -only='base-fedora.*' .
# =============================================================================

// Variables defined in variables.pkr.hcl:
//   ssh_enterprise_key_file, network_gateway, network_cidr_mask,
//   base_fedora_vmid, fedora_image_url

source "null" "fedora-base" {
  communicator = "none"
}

build {
  name    = "base-fedora"
  sources = ["source.null.fedora-base"]

  # Download Fedora cloud image locally
  provisioner "shell-local" {
    inline = [
      "echo '[+] Downloading Fedora Cloud image...'",
      "IMG=/tmp/fedora-cloud-base.qcow2",
      "if [ -f $IMG ]; then",
      "  echo '    Image already downloaded, skipping'",
      "else",
      "  curl -L -o $IMG '${var.fedora_image_url}'",
      "fi",
      "ls -lh $IMG"
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
      "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $SSH_KEY /tmp/fedora-cloud-base.qcow2 root@$PROXMOX_HOST:/tmp/fedora-cloud-base.qcow2"
    ]
  }

  # Create the template on Proxmox
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

      ssh $SSH_OPTS root@$PROXMOX_HOST bash -s -- \
        "${var.base_fedora_vmid}" \
        "${var.template_storage}" \
        "${var.template_storage_type}" \
        "${var.network_bridge}" \
        "${var.ssh_username}" \
        "${var.ssh_password}" \
        <<'REMOTE_SCRIPT'
      set -euo pipefail
      VMID="$1"; STORAGE="$2"; STORAGE_TYPE="$3"; BRIDGE="$4"; SSH_USER="$5"; SSH_PASS="$6"
      IMAGE="/tmp/fedora-cloud-base.qcow2"

      echo "[+] Checking for existing VM $VMID..."
      if qm status "$VMID" >/dev/null 2>&1; then
        echo "    Destroying existing VM $VMID..."
        qm stop "$VMID" --skiplock true 2>/dev/null || true
        qm destroy "$VMID" --purge true --destroy-unreferenced-disks true
      fi

      echo "[+] Creating VM $VMID..."
      qm create "$VMID" --name "fedora-base-template" --cores 2 --memory 2048 \
        --agent enabled=1 --scsihw virtio-scsi-pci --net0 "virtio,bridge=$BRIDGE"

      echo "[+] Importing disk to storage $STORAGE..."
      qm importdisk "$VMID" "$IMAGE" "$STORAGE"

      case "$STORAGE_TYPE" in
        nfs|dir|cifs) DISK_REF="$STORAGE:$VMID/vm-$VMID-disk-0.raw" ;;
        *)            DISK_REF="$STORAGE:vm-$VMID-disk-0" ;;
      esac

      qm set "$VMID" --scsi0 "$DISK_REF"
      echo "[+] Resizing disk to 32G..."
      qm disk resize "$VMID" scsi0 32G
      qm set "$VMID" --boot order=scsi0
      qm set "$VMID" --ide2 "$STORAGE:cloudinit"
      qm set "$VMID" --ciuser "$SSH_USER" --cipassword "$SSH_PASS" \
        --ipconfig0 "ip=dhcp" --serial0 socket --vga serial0

      rm -f "$IMAGE"
      echo "[+] VM $VMID configured (agent install pending)"
      REMOTE_SCRIPT
      SCRIPT
    ]
  }

  # Inject SSH public key
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_URL=${var.proxmox_url}",
      "VMID=${var.base_fedora_vmid}",
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
      fi
      SCRIPT
    ]
  }

  # Boot VM, install qemu-guest-agent, revert to DHCP, template
  provisioner "shell-local" {
    environment_vars = [
      "PROXMOX_URL=${var.proxmox_url}",
      "VMID=${var.base_fedora_vmid}",
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
        echo "[!] network_gateway not set — templating without guest agent"
        ssh $PVE_SSH root@$PROXMOX_HOST "qm template $VMID"
        exit 0
      fi

      TEMP_IP=$(echo "$NETWORK_GW" | sed 's/\.[0-9]*$/.253/')
      echo "[+] Temp IP: $TEMP_IP/$NETWORK_CIDR"

      ssh $PVE_SSH root@$PROXMOX_HOST \
        "qm set $VMID --ipconfig0 ip=$TEMP_IP/$NETWORK_CIDR,gw=$NETWORK_GW && qm start $VMID"

      VM_SSH="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i /crypto/labadmin"
      echo "[+] Waiting for SSH on $TEMP_IP..."
      for i in $(seq 1 40); do
        if ssh $VM_SSH $SSH_USER@$TEMP_IP 'echo OK' 2>/dev/null | grep -q OK; then
          echo "    SSH available"; break
        fi
        sleep 5
      done

      echo "[+] Waiting for cloud-init (timeout 120s)..."
      ssh $VM_SSH $SSH_USER@$TEMP_IP 'timeout 120 cloud-init status --wait' 2>/dev/null || true

      echo "[+] Installing qemu-guest-agent (dnf)..."
      ssh $VM_SSH $SSH_USER@$TEMP_IP \
        'sudo dnf install -y -q qemu-guest-agent && sudo systemctl enable qemu-guest-agent && sudo systemctl start qemu-guest-agent && echo AGENT_OK'

      ssh $PVE_SSH root@$PROXMOX_HOST "qm shutdown $VMID --timeout 30 2>/dev/null || qm stop $VMID"
      sleep 5
      ssh $PVE_SSH root@$PROXMOX_HOST "qm set $VMID --ipconfig0 ip=dhcp"
      ssh $PVE_SSH root@$PROXMOX_HOST "qm template $VMID"
      echo "[+] Base Fedora template $VMID created successfully"
      SCRIPT
    ]
  }
}
