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
          # State on each Nomad VM's local disk. System job + per-node
          # bind-mount means each alloc reads/writes its own host's path —
          # no collisions, no shared filesystem required. Cluster_state
          # NAS-side snapshots wouldn't help here (tailscaled.state is
          # current-or-new credentials, not rollback-friendly).
          "/var/lib/tailscale-state:/var/lib/tailscale",
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
