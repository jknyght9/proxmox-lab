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

    task "traefik" {
      driver = "docker"

      volume_mount {
        volume      = "traefik-data"
        destination = "/data"
      }

      config {
        image        = "traefik:v3.6"
        network_mode = "host"
        dns_servers  = ["${DNS_SERVER}"]
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
