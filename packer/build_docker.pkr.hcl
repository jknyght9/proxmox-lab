build {
  name = "ubuntu-docker"
  sources = ["source.proxmox-clone.ubuntu-docker"]

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
      "sudo apt-get install -y apt-transport-https ca-certificates curl gnupg jq software-properties-common",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -",
      "sudo add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\"",
      "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
      "sudo usermod -aG docker $USER"
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
      "sudo apt-get install -y cloud-init qemu-guest-agent",
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
              ssh_password: $ssh_password
            }]' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      EOF
    ]
  }
}
