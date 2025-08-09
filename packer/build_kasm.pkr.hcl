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
      "echo '[+] Installing Docker'",
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common",
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

  provisioner "shell" {
    inline = [
      "echo '[+] Enabling qemu-guest-agent and cloud-init'",
      "sudo apt-get install -y cloud-init qemu-guest-agent",
      "sudo systemctl enable qemu-guest-agent",
      "sudo systemctl enable cloud-init cloud-init-local",
      "echo '[+] Resetting cloud-init for template'",
      "sudo cloud-init clean --logs",
      "sudo tee /etc/netplan/01-netcfg.yaml <<EOF\nnetwork:\n  version: 2\n  ethernets:\n    ens18:\n      dhcp4: true\nEOF",
      "sudo chmod 600 /etc/netplan/01-netcfg.yaml",
      "sudo netplan generate"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Cleaning up'",
      "sudo rm /etc/ssh/ssh_host_*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo apt-get -y autoremove --purge",
      "sudo apt-get -y clean",
      "sudo apt-get -y autoclean"
    ]
  }
}