job "tailscale" {
  datacenters = ["dc1"]
  type        = "system"

  group "tailscale" {
    network {
      mode = "host"
    }

    vault {
      role = "tailscale"
    }

    # Belt-and-suspenders: refuse to start if the gluster volume isn't
    # actually mounted (host-level RequiresMountsFor should already guarantee
    # this, but this catches manual-unmount and runtime-drop edge cases).
    task "wait-for-gluster" {
      driver = "raw_exec"
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      config {
        command = "/bin/bash"
        args = [
          "-c",
          "mountpoint -q /srv/gluster/nomad-data && test -f /srv/gluster/nomad-data/.mount-sentinel"
        ]
      }
      resources {
        cpu    = 10
        memory = 16
      }
    }

    # Tailscale containerboot installs forward rules in iptables-legacy,
    # but Docker installs a FORWARD-DROP policy in iptables-nft. On
    # kernels where both backends are active simultaneously, Docker's
    # nft DROP wins — every packet from a remote tailnet client through
    # tailscale0 → 10.10.0.0/24 is silently dropped. Symptom: subnet
    # routes show approved on Tailscale admin, ping over tailnet to a
    # lab IP fails with no obvious error.
    #
    # DOCKER-USER is the Docker-blessed escape hatch for user rules
    # that take precedence over Docker's chain. -C tests for presence
    # so reapply on alloc restart is a no-op.
    task "setup-iptables" {
      driver = "raw_exec"
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      config {
        command = "/bin/bash"
        args = [
          "-c",
          "sudo iptables -C DOCKER-USER -i tailscale0 -j ACCEPT 2>/dev/null || sudo iptables -I DOCKER-USER -i tailscale0 -j ACCEPT && sudo iptables -C DOCKER-USER -o tailscale0 -j ACCEPT 2>/dev/null || sudo iptables -I DOCKER-USER -o tailscale0 -j ACCEPT"
        ]
      }
      resources {
        cpu    = 10
        memory = 16
      }
    }

    task "tailscale" {
      driver = "docker"

      config {
        image        = "tailscale/tailscale:v1.92.4"
        network_mode = "host"
        privileged   = true

        volumes = [
          # Per-node state directory to avoid conflicts
          "/srv/gluster/nomad-data/tailscale/$${node.unique.name}:/var/lib/tailscale",
          "/dev/net/tun:/dev/net/tun",
        ]
      }

      template {
        data = <<EOH
# Subnet to advertise (set during deployment via envsubst)
TS_ROUTES=${tailscale_subnet}
TS_STATE_DIR=/var/lib/tailscale
TS_USERSPACE=false
TS_ACCEPT_DNS=false
# Auth key from Vault (reusable, pre-authorized)
{{ with secret "secret/data/tailscale" }}
TS_AUTHKEY={{ .Data.data.auth_key }}
{{ end }}
EOH
        destination = "secrets/tailscale.env"
        env         = true
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
