variable "tailscale_subnet" {
  type        = string
  description = "Subnet to advertise via Tailscale (e.g., 10.1.50.0/24)"
}

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

    task "tailscale" {
      driver = "docker"

      config {
        image        = "tailscale/tailscale:latest"
        network_mode = "host"
        privileged   = true

        volumes = [
          # Per-node state directory to avoid conflicts
          "/srv/gluster/nomad-data/tailscale/${node.unique.name}:/var/lib/tailscale",
          "/dev/net/tun:/dev/net/tun",
        ]
      }

      template {
        data = <<EOH
# Subnet to advertise (set during deployment via envsubst)
TS_ROUTES=${var.tailscale_subnet}
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
