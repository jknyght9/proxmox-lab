variable "dns_server" {
  type        = string
  description = "DNS server IP for Traefik container (Pi-hole VIP or primary node)"
}

job "traefik" {
  datacenters = ["dc1"]
  # System job runs on all nodes for HA (keepalived VIP handles failover)
  # Note: Set to "service" with count=1 and hostname constraint if HA is disabled
  type        = "system"

  group "traefik" {
    # System jobs don't use count - they run on all eligible nodes

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

      config {
        image        = "traefik:v3.6"
        network_mode = "host"
        dns_servers  = ["${var.dns_server}"]
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
          "--providers.file.directory=/data/traefik/config",
          "--providers.file.watch=true",
          # Allow HTTPS backend connections (Vault serves HTTPS with its own PKI cert)
          "--serversTransport.insecureSkipVerify=true",
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
