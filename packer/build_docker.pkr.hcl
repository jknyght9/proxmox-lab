build {
  name = "ubuntu-docker"
  sources = ["source.proxmox-clone.ubuntu-docker"]

  provisioner "shell" {
    inline = [
      "echo '[+] Waiting for cloud-init to finish...'",
      "cloud-init status --wait || true",
      "sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y",
      "echo \"root:${var.root_password}\" | sudo chpasswd"
    ]
  }

  # Upload and install SSH public key (Packer cloning clears cloud-init sshkeys)
  provisioner "file" {
    source      = var.ssh_public_key_file
    destination = "/tmp/labadmin.pub"
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Installing SSH public key'",
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh",
      "cat /tmp/labadmin.pub >> ~/.ssh/authorized_keys",
      "chmod 600 ~/.ssh/authorized_keys",
      "rm /tmp/labadmin.pub"
    ]
  }

  # Upload local CA cert (generated during setup.sh step-ca phase)
  # Mounted at /step-ca-certs in the packer container (see compose.yml)
  provisioner "file" {
    source      = "/step-ca-certs/root_ca.crt"
    destination = "/tmp/proxmox-lab-root-ca.crt"
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Installing internal certificate authority'",
      "sudo install -m 0644 /tmp/proxmox-lab-root-ca.crt /usr/local/share/ca-certificates/proxmox-lab-root-ca.crt",
      "sudo update-ca-certificates --fresh",
      "rm /tmp/proxmox-lab-root-ca.crt"
    ]
  }

  #### Install software
  provisioner "shell" {
    inline = [
      "echo '[+] Installing acme.sh'",
      "curl https://get.acme.sh | sh -s email=admin@${var.dns_postfix}",
      "~/.acme.sh/acme.sh --version"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Installing Docker'",
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get update",
      "sudo apt-get install -y ca-certificates curl jq software-properties-common socat",
      "curl -fsSL https://get.docker.com | sh",
      "sudo usermod -aG docker ${var.ssh_username}"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Installing GlusterFS'",
      "sudo apt-get install glusterfs-server -y",
      "sudo systemctl start glusterd",
      "sudo systemctl enable glusterd",
      "sudo mkdir -p /gluster/volume1"
    ]
  }

  #### Cloud-init configuration
  provisioner "shell" {
    inline = [
      "echo '[+] Enabling qemu-guest-agent and cloud-init'",
      "sudo apt-get update && sudo apt-get upgrade -y",
      "sudo apt-get install -y --no-install-recommends cloud-init qemu-guest-agent",
      "sudo systemctl enable qemu-guest-agent",
      "sudo systemctl enable cloud-init cloud-init-local",
      "sudo cloud-init clean --logs || true",
      "sudo rm -rf /var/lib/cloud/instance /var/lib/cloud/instances",
      "sudo rm -rf /var/lib/cloud/seed/nocloud",
      "sudo bash -lc 'cat >/etc/netplan/01-netcfg.yaml <<EOF\nnetwork:\n  version: 2\n  ethernets:\n    all-en:\n      match:\n        name: \"en*\"\n      dhcp4: true\nEOF'",
      "sudo chmod 600 /etc/netplan/01-netcfg.yaml",
      "sudo netplan generate"
    ]
  }

  #### Generalize and clean up after APT
  provisioner "shell" {
    scripts = ["files/linux-generalize.sh"]
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Cleaning up APT'",
      "sudo apt-get -y autoremove --purge",
      "sudo apt-get -y clean",
      "sudo apt-get -y autoclean"
    ]
  }

  #### Output variables to JSON file
  provisioner "shell-local" {
    inline = [
      "umask 077",
      "mkdir -p packer-outputs",
      "build=\"docker\"",
      "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      <<-EOF
        file=packer-outputs/template-credentials.json

        # Create an empty JSON array if the file doesn't exist yet
        if [ ! -f "$file" ]; then
          echo "[]" > "$file"
        fi

        # Append a new object to the array
        jq --arg build "$build" \
          --arg ts "$ts" \
          --arg root_password "${var.root_password}" \
          --arg ssh_username "${var.ssh_username}" \
          --arg ssh_password "${var.ssh_password}" \
          '. += [{
              build: $build,
              timestamp: $ts,
              root_password: $root_password,
              ssh_username: $ssh_username,
              ssh_password: $ssh_password,
            }]' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      EOF
    ]
  }
}
