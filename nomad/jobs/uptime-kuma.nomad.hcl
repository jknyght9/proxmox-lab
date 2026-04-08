job "uptime-kuma" {
  datacenters = ["dc1"]
  type        = "service"

  group "uptime-kuma" {
    count = 1

    # Pin to nomad01 for consistency with other services
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }

    network {
      mode = "host"
      port "http" { static = 3001 }
    }

    task "uptime-kuma" {
      driver = "docker"

      config {
        image        = "louislam/uptime-kuma:1"
        network_mode = "host"
        volumes = [
          "/srv/gluster/nomad-data/uptime-kuma:/app/data",
        ]
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
          "traefik.http.routers.uptime-kuma-http.rule=Host(`status.${DNS_POSTFIX}`) || Host(`status`)",
          "traefik.http.routers.uptime-kuma-http.entrypoints=web",
          # HTTPS router with TLS - accepts both FQDN and short name
          "traefik.http.routers.uptime-kuma.rule=Host(`status.${DNS_POSTFIX}`) || Host(`status`)",
          "traefik.http.routers.uptime-kuma.entrypoints=websecure",
          "traefik.http.routers.uptime-kuma.tls=true",
          "traefik.http.routers.uptime-kuma.tls.certresolver=vault-pki",
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
