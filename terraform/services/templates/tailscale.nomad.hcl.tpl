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

    task "tailscale" {
      driver = "docker"

      config {
        image        = "tailscale/tailscale:latest"
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
