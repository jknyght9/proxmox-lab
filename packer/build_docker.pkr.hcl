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
      "echo '[+] Installing Docker'",
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl gnupg software-properties-common",
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
