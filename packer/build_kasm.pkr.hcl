build {
  name = "ubuntu-kasm"
  sources = ["source.proxmox-clone.ubuntu-kasm"]

  provisioner "shell" {
    inline = [
      "echo '[+] Waiting for cloud-init to finish...'",
      "cloud-init status --wait || true"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo \"root:${var.root_password}\" | sudo chpasswd"
    ]
  }

  #### Install software

  provisioner "shell" {
    inline = [
      "echo '[+] Installing Docker'",
      "export DEBIAN_FRONTEND=noninteractive",
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl jq software-properties-common",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -",
      "sudo add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\"",
      "sudo apt-get install -y docker-ce docker-ce-cli containerd.io",
      "sudo usermod -aG docker $USER"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Installing Kasm Workspaces'",
      "sudo apt-get update",
      "sudo apt-get install -y docker-compose-plugin",
      "sudo fallocate -l 4G /swapfile",
      "sudo chmod 600 /swapfile",
      "sudo mkswap /swapfile",
      "sudo swapon /swapfile",
      "echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab",
      "curl -O https://kasm-static-content.s3.amazonaws.com/kasm_release_${var.kasm_version}.tar.gz",
      "tar -xf kasm_release_${var.kasm_version}.tar.gz",
      "sudo bash kasm_release/install.sh --accept-eula --admin-password ${var.kasm_admin_password} --proxy-port 8443",
      "rm -rf kasm_release*"
    ]
  }

  #### Cloud-init configuration

  provisioner "shell" {
    inline = [
      "echo '[+] Enabling qemu-guest-agent and cloud-init'",
      "sudo apt-get update && sudo apt-get upgrade -y",
      "sudo apt-get install -y --no-install-recommends cloud-init qemu-guest-agent",
      "sudo systemctl enable qemu-guest-agent",
      "sudo systemctl enable cloud-init cloud-init-local"
    ]
  }

  provisioner "file" {
    destination = "/tmp/user-data"
    content = <<-CLOUD
      #cloud-config
      users:
        - name: ${var.ssh_username}
          groups: [sudo]
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - ${file(var.ssh_public_key_file)}

        - name: root
          ssh_authorized_keys:
            - ${file(var.ssh_public_key_file)}
    CLOUD
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Resetting cloud-init for template'",
      "sudo mkdir -p /var/lib/cloud/seed/nocloud",
      "echo 'instance-id: iid-local-template' | sudo tee /var/lib/cloud/seed/nocloud/meta-data >/dev/null",
      "sudo mv /tmp/user-data /var/lib/cloud/seed/nocloud/user-data",
      "sudo chmod 600 /var/lib/cloud/seed/nocloud/user-data /var/lib/cloud/seed/nocloud/meta-data",
      "sudo cloud-init clean --logs",
      "sudo tee /etc/netplan/01-netcfg.yaml <<EOF\nnetwork:\n  version: 2\n  ethernets:\n    ens18:\n      dhcp4: true\nEOF",
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
      "build=\"kasm\"",
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
          --arg kasm_admin_password "${var.kasm_admin_password}" \
          '. += [{
              build: $build,
              timestamp: $ts,
              root_password: $root_password,
              ssh_username: $ssh_username,
              ssh_password: $ssh_password,
              kasm_admin_password: $kasm_admin_password,
            }]' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      EOF
    ]
  }
}
