build {
  name = "ubuntu-docker"
  sources = ["source.proxmox-clone.ubuntu-docker"]

  provisioner "shell" {
    inline = [
      "echo '[+] Waiting for cloud-init to finish...'",
      "cloud-init status --wait || true",
      # Some lab networks block outbound HTTP/80; archive and security
      # mirrors fail with "Connection failed". Both sites support HTTPS,
      # so rewrite sources before the first apt call.
      # Covers Ubuntu 24.04's deb822 file (.sources) AND legacy .list.
      "echo '[+] Switching apt sources to HTTPS...'",
      "sudo find /etc/apt -type f \\( -name '*.list' -o -name '*.sources' \\) -exec sed -i 's|http://archive\\.ubuntu\\.com|https://archive.ubuntu.com|g; s|http://security\\.ubuntu\\.com|https://security.ubuntu.com|g' {} +",
      "sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y",
      "echo \"root:${var.root_password}\" | sudo chpasswd"
    ]
  }

  # Fetch root CA directly from Vault PKI (unauthenticated endpoint).
  # Skipped when vault_addr is empty (Vault not yet deployed).
  provisioner "shell" {
    inline = [
      "VAULT_ADDR='${var.vault_addr}'",
      "if [ -n \"$VAULT_ADDR\" ]; then",
      "  echo '[+] Installing internal certificate authority from Vault PKI'",
      "  curl -sk $VAULT_ADDR/v1/pki/ca/pem -o /tmp/proxmox-lab-root-ca.crt",
      "  sudo install -m 0644 /tmp/proxmox-lab-root-ca.crt /usr/local/share/ca-certificates/proxmox-lab-root-ca.crt",
      "  sudo update-ca-certificates --fresh",
      "  rm /tmp/proxmox-lab-root-ca.crt",
      "else",
      "  echo '[!] vault_addr not set — skipping root CA install (Vault not deployed yet)'",
      "fi"
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
      # Do NOT start glusterd here — starting it generates a UUID at
      # /var/lib/glusterd/glusterd.info which would be baked into the
      # template and inherited by every clone, breaking peer probe.
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
      "sudo rm -f /etc/netplan/*.yaml",
      "echo '[+] Netplan cleared — Proxmox cloud-init handles network config at deploy time'"
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

  # Defense in depth: even though we don't start glusterd above, wipe
  # any per-host glusterd identity at template seal so cloned VMs
  # always boot identity-free.
  provisioner "shell" {
    inline = [
      "echo '[+] Resetting GlusterFS identity for clean clones'",
      "sudo systemctl stop glusterd 2>/dev/null || true",
      "sudo rm -rf /var/lib/glusterd/peers /var/lib/glusterd/glusterd.info /var/lib/glusterd/vols /var/lib/glusterd/snaps",
      "sudo mkdir -p /var/lib/glusterd/peers"
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
