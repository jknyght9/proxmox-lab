build {
  name = "ubuntu-nomad"
  sources = ["source.proxmox-clone.ubuntu-nomad"]

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
      # template and inherited by every clone, breaking peer probe
      # (all clones present the same identity). Enable only; first
      # boot of each clone generates its own UUID.
      "sudo systemctl enable glusterd",
      "sudo mkdir -p /gluster/volume1"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Installing HashiCorp Nomad'",
      "export DEBIAN_FRONTEND=noninteractive",
      "wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list",
      "sudo apt-get update",
      "sudo apt-get install -y nomad",
      "sudo systemctl enable nomad",
      "nomad --version"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Installing CNI plugins for Nomad networking'",
      "curl -L -o /tmp/cni-plugins.tgz https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz",
      "sudo mkdir -p /opt/cni/bin",
      "sudo tar -C /opt/cni/bin -xzf /tmp/cni-plugins.tgz",
      "rm /tmp/cni-plugins.tgz"
    ]
  }

  # Sequence Docker and Nomad after the GlusterFS mount so jobs never
  # bind-mount a pre-mount empty local directory on boot. Pairs with the
  # x-systemd.* options written into fstab by deployNomad.sh.
  #
  # The glusterd drop-in fixes a cold-boot race: glusterd.service reaches
  # `active` ~3s before its localhost RPC can answer `gluster volume list`,
  # so the fstab mount unit (ordered `x-systemd.after=glusterd.service`)
  # fires too early and fails permanently with no retry. The ExecStartPost
  # gate blocks systemd from marking glusterd active until volume listing
  # actually responds, so downstream ordering means what it says.
  provisioner "shell" {
    inline = [
      "echo '[+] Installing systemd drop-ins: glusterd readiness + docker/nomad wait for GlusterFS mount'",
      "sudo mkdir -p /etc/systemd/system/glusterd.service.d /etc/systemd/system/docker.service.d /etc/systemd/system/nomad.service.d",
      "printf '[Service]\\nExecStartPost=/bin/bash -c \"for i in {1..60}; do gluster volume list >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1\"\\n' | sudo tee /etc/systemd/system/glusterd.service.d/wait-ready.conf > /dev/null",
      "printf '[Unit]\\nRequiresMountsFor=/srv/gluster/nomad-data\\n' | sudo tee /etc/systemd/system/docker.service.d/wait-gluster.conf > /dev/null",
      "printf '[Unit]\\nRequiresMountsFor=/srv/gluster/nomad-data\\n' | sudo tee /etc/systemd/system/nomad.service.d/wait-gluster.conf > /dev/null",
      "sudo systemctl daemon-reload"
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '[+] Installing keepalived for Traefik HA'",
      "sudo apt-get install -y keepalived",
      "sudo systemctl disable keepalived"
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
  # always boot identity-free. Pairs with terraform/vm-nomad/main.tf
  # gluster_init, which expects each clone to generate a fresh UUID
  # the first time glusterd starts.
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
      "build=\"nomad\"",
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
