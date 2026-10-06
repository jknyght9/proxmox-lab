locals {
  proxmox_api_host = regex("^https?://([^:/]+)", var.proxmox_endpoint)[0]

  # Host paths shared with the runner and with every job container. The host
  # CA bundle (public roots + the internal root CA after update-ca-certificates)
  # is bind-mounted read-only so git/curl/node inside jobs trust git.<postfix>.
  ca_bundle = "/etc/ssl/certs/ca-certificates.crt"

  runner_config = yamlencode({
    log = { level = "info" }
    runner = {
      file           = "/data/.runner"
      capacity       = var.runner_capacity
      timeout        = "4h"
      fetch_timeout  = "5s"
      fetch_interval = "2s"
      # Labels live here (not only in .runner) so changing var.runner_labels
      # takes effect on the next apply without re-registering.
      labels = split(",", var.runner_labels)
    }
    cache = { enabled = false }
    container = {
      network    = ""
      privileged = false
      # Jobs get the VM's own Docker daemon at /var/run/docker.sock: they build
      # and push images with plain `docker`. This makes every job root-
      # equivalent on THIS VM, which is the point of a dedicated build VM.
      docker_host   = "automount"
      valid_volumes = [local.ca_bundle, "/var/run/docker.sock"]
      options = join(" ", [
        "--volume ${local.ca_bundle}:${local.ca_bundle}:ro",
        "--env NODE_EXTRA_CA_CERTS=${local.ca_bundle}",
        "--env GIT_SSL_CAINFO=${local.ca_bundle}",
      ])
      force_pull = false
    }
    host = { workdir_parent = "/data/workdir" }
  })
}

# Render cloud-init user data templates
resource "local_file" "builder_user_data" {
  for_each = var.vm_configs
  filename = "${path.module}/rendered/${each.value.name}-user-data.yml"
  content = templatefile("${path.module}/cloudinit/builder-user-data.tmpl", {
    hostname            = each.value.name
    ssh_authorized_keys = file(var.ssh_admin_public_key_file)
  })
}

# Upload cloud-init snippets to Proxmox node via SSH
resource "null_resource" "upload_snippet" {
  for_each   = var.vm_configs
  depends_on = [local_file.builder_user_data]
  triggers = {
    sha = sha256(local_file.builder_user_data[each.key].content)
  }
  connection {
    type        = "ssh"
    host        = lookup(var.node_ip_map, each.value.target_node, local.proxmox_api_host)
    user        = "root"
    private_key = file(var.ssh_enterprise_private_key_file)
  }
  provisioner "remote-exec" {
    inline = ["mkdir -p /var/lib/vz/snippets"]
  }
  provisioner "file" {
    source      = local_file.builder_user_data[each.key].filename
    destination = "/var/lib/vz/snippets/${each.value.name}-user-data.yml"
  }
}

# Build-runner VM (bpg/proxmox provider)
resource "proxmox_virtual_environment_vm" "builder" {
  for_each   = var.vm_configs
  depends_on = [null_resource.upload_snippet]

  vm_id     = each.value.vm_id
  name      = each.value.name
  node_name = each.value.target_node
  on_boot   = true
  tags      = ["terraform", "infra", "vm", "builder"]

  clone {
    vm_id     = 9001 # docker-template
    node_name = var.template_node
  }

  agent {
    enabled = true
  }

  cpu {
    sockets = 1
    cores   = each.value.cores
    type    = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    interface    = "scsi0"
    size         = tonumber(replace(each.value.disk_size, "G", ""))
    datastore_id = each.value.target_storage
  }

  network_device {
    bridge = var.proxmox_bridge
    model  = "virtio"
  }

  initialization {
    user_account {
      username = "labadmin"
      keys     = [trimspace(file(var.ssh_admin_public_key_file))]
    }
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_cidr_bits}"
        gateway = var.network_gateway
      }
    }
    dns {
      # Gateway DNS: resolves internal names for job containers too (Docker
      # hands the host's upstream resolvers to bridge-network containers).
      servers = [var.network_gateway]
      domain  = var.dns_postfix
    }
    user_data_file_id = "local:snippets/${each.value.name}-user-data.yml"
  }

  lifecycle {
    ignore_changes = [
      clone,
      disk[0].size,
    ]
  }
}

# =============================================================================
# Build-runner configuration (managed by Terraform, not cloud-init)
# =============================================================================

# Trust the internal root CA system-wide. Docker uses the system pool for
# registry TLS, so this also lets `docker push git.<postfix>/...` work.
resource "null_resource" "builder_ca_trust" {
  for_each   = var.vm_configs
  depends_on = [proxmox_virtual_environment_vm.builder]

  triggers = {
    vm_id  = proxmox_virtual_environment_vm.builder[each.key].vm_id
    ca_sha = sha256(var.root_ca_pem)
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "file" {
    content     = var.root_ca_pem
    destination = "/tmp/lab-root-ca.crt"
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e
      cloud-init status --wait >/dev/null 2>&1 || true
      if ! grep -q 'BEGIN CERTIFICATE' /tmp/lab-root-ca.crt; then
        echo '[-] No root CA from Vault (pki/cert/ca); is Vault configured?'
        exit 1
      fi
      sudo install -m 0644 /tmp/lab-root-ca.crt /usr/local/share/ca-certificates/lab-root-ca.crt
      rm -f /tmp/lab-root-ca.crt
      sudo update-ca-certificates
      sudo systemctl restart docker
      echo '[+] Internal root CA trusted on ${each.value.name}'
      EOT
    ]
  }
}

# Register (once) and run forgejo-runner as a container on the host daemon.
resource "null_resource" "builder_runner" {
  for_each   = var.vm_configs
  depends_on = [null_resource.builder_ca_trust]

  triggers = {
    vm_id      = proxmox_virtual_environment_vm.builder[each.key].vm_id
    image      = var.runner_image
    config_sha = sha256(local.runner_config)
    ca_sha     = sha256(var.root_ca_pem)
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "file" {
    content     = local.runner_config
    destination = "/tmp/forgejo-runner-config.yaml"
  }

  # Token goes over as a file (not in the inline script) so the provisioner's
  # output isn't suppressed as sensitive and the token never hits argv logs.
  provisioner "file" {
    content     = var.runner_registration_token
    destination = "/tmp/.forgejo-runner-token"
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e
      D=/var/lib/forgejo-runner
      RUN="sudo docker run --user 0:0 -v $D:/data -v ${local.ca_bundle}:${local.ca_bundle}:ro -e SSL_CERT_FILE=${local.ca_bundle}"
      sudo install -d -m 0750 $D
      sudo install -m 0640 /tmp/forgejo-runner-config.yaml $D/config.yaml
      rm -f /tmp/forgejo-runner-config.yaml

      if ! sudo test -s $D/.runner; then
        if [ ! -s /tmp/.forgejo-runner-token ]; then
          rm -f /tmp/.forgejo-runner-token
          echo '[-] No registration token in secret/forgejo-runner; deploy the services-layer forgejo-runner first.'
          exit 1
        fi
        echo '[+] Registering ${each.value.name} with https://git.${var.dns_postfix} ...'
        $RUN --rm ${var.runner_image} forgejo-runner register --no-interactive \
          --config /data/config.yaml \
          --instance https://git.${var.dns_postfix} \
          --token "$(cat /tmp/.forgejo-runner-token)" \
          --name ${each.value.name} \
          --labels '${var.runner_labels}'
      fi
      rm -f /tmp/.forgejo-runner-token

      sudo docker rm -f forgejo-runner >/dev/null 2>&1 || true
      $RUN -d --name forgejo-runner --restart unless-stopped \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -e DOCKER_HOST=unix:///var/run/docker.sock \
        ${var.runner_image} forgejo-runner daemon --config /data/config.yaml

      # Heavy images churn the disk: nightly prune of unused images + build cache.
      echo '30 3 * * * root docker image prune -af --filter until=${var.docker_prune_until} >/dev/null && docker builder prune -af --filter until=${var.docker_prune_until} >/dev/null' \
        | sudo tee /etc/cron.d/docker-prune >/dev/null

      sleep 5
      sudo docker logs --tail 5 forgejo-runner
      echo '[+] forgejo-runner running on ${each.value.name} (labels: ${var.runner_labels})'
      EOT
    ]
  }
}
