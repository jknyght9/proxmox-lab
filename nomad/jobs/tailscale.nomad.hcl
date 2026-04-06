job "tailscale" {
  datacenters = ["dc1"]
  type        = "service"

  group "tailscale" {
    count = 1

    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }

    network {
      mode = "host"
    }

    task "tailscale" {
      driver = "docker"

      config {
        image        = "tailscale/tailscale:latest"
        network_mode = "host"
        privileged   = true

        volumes = [
          "/srv/gluster/nomad-data/tailscale:/var/lib/tailscale",
          "/dev/net/tun:/dev/net/tun",
        ]
      }

      env {
        # Subnet to advertise (set during deployment via envsubst)
        TS_ROUTES              = "${TAILSCALE_SUBNET}"
        TS_STATE_DIR           = "/var/lib/tailscale"
        TS_USERSPACE           = "false"
        TS_ACCEPT_DNS          = "false"
        # Auth key can be set here or authenticate interactively
        # TS_AUTHKEY           = "tskey-auth-xxxxx"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
