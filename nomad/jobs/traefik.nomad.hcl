job "traefik" {
  datacenters = ["dc1"]
  type        = "service"

  group "traefik" {
    count = 1

    # Run on a single node to avoid ACME challenge distribution issues
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }
    network {
      mode = "host"
      port "http"      { static = 80 }
      port "https"     { static = 443 }
      port "dashboard" { static = 8081 }
    }

    volume "traefik-data" {
      type   = "host"
      source = "gluster-data"
    }

    task "traefik" {
      driver = "docker"

      volume_mount {
        volume      = "traefik-data"
        destination = "/data"
      }

      env {
        # Trust the internal CA for ACME requests
        SSL_CERT_FILE = "/data/certs/root_ca.crt"
        LEGO_CA_CERTIFICATES = "/data/certs/root_ca.crt"
      }

      config {
        image        = "traefik:v3.6"
        network_mode = "host"
        args = [
          "--log.level=DEBUG",
          "--api=true",
          "--api.dashboard=true",
          "--api.insecure=true",
          "--ping=true",
          "--ping.entryPoint=traefik",
          "--entrypoints.web.address=:80",
          "--entrypoints.websecure.address=:443",
          "--entrypoints.traefik.address=:8081",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://127.0.0.1:4646",
          "--providers.nomad.exposedByDefault=false",
          "--providers.nomad.namespaces=default",
          "--providers.nomad.allowEmptyServices=true",
          "--certificatesresolvers.step-ca.acme.email=admin@${DNS_POSTFIX}",
          "--certificatesresolvers.step-ca.acme.storage=/data/traefik/acme.json",
          "--certificatesresolvers.step-ca.acme.caserver=https://ca.${DNS_POSTFIX}/acme/acme/directory",
          "--certificatesresolvers.step-ca.acme.httpchallenge=true",
          "--certificatesresolvers.step-ca.acme.httpchallenge.entrypoint=web",
        ]
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "traefik"
        port     = "dashboard"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/ping"
          port     = "dashboard"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
