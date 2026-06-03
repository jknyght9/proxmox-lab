job "uptime-kuma" {
  datacenters = ["dc1"]
  type        = "service"

  group "uptime-kuma" {
    count = 1

    # Pin to nomad01 for consistency with other services
    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    network {
      mode = "host"
      port "http" { static = 3001 }
    }

    # State lives on the cluster_state NAS via the csi-driver-nfs plugin.
    # See terraform/services/nas-shares.tf for dataset/share provisioning
    # and csi-volumes.tf for the volume registration.
    volume "data" {
      type            = "csi"
      source          = "uptime-kuma-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    task "uptime-kuma" {
      driver = "docker"

      config {
        # 2.x ships with UPTIME_KUMA_ENABLE_EMBEDDED_MARIADB=1 baked into
        # the image — no external DB sidecar required. Data layout under
        # /app/data differs from 1.x (MariaDB files vs SQLite kuma.db),
        # so a first-time start against an empty directory is expected.
        image        = "louislam/uptime-kuma:2.2.1"
        network_mode = "host"
      }

      volume_mount {
        volume      = "data"
        destination = "/app/data"
        read_only   = false
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "uptime-kuma"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          # HTTP router for ACME challenges and short name
          "traefik.http.routers.uptime-kuma-http.rule=Host(`status.${dns_postfix}`) || Host(`status`)",
          "traefik.http.routers.uptime-kuma-http.entrypoints=web",
          # HTTPS router with TLS - accepts both FQDN and short name
          "traefik.http.routers.uptime-kuma.rule=Host(`status.${dns_postfix}`) || Host(`status`)",
          "traefik.http.routers.uptime-kuma.entrypoints=websecure",
          "traefik.http.routers.uptime-kuma.tls=true",
          "traefik.http.services.uptime-kuma.loadbalancer.server.port=3001",
        ]

        check {
          type     = "http"
          path     = "/"
          port     = "http"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
