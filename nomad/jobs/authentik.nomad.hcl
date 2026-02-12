job "authentik" {
  datacenters = ["dc1"]
  type        = "service"

  group "authentik" {
    count = 1

    network {
      mode = "host"
      port "http"     { static = 9000 }
      port "https"    { static = 9443 }
      port "postgres" { static = 5432 }
      port "redis"    { static = 6379 }
    }

    volume "authentik-data" {
      type   = "host"
      source = "gluster-data"
    }

    # PostgreSQL - Database for Authentik
    task "postgres" {
      driver = "docker"

      volume_mount {
        volume      = "authentik-data"
        destination = "/data"
      }

      config {
        image        = "postgres:16-alpine"
        network_mode = "host"
        volumes = [
          "/srv/gluster/nomad-data/authentik/postgres:/var/lib/postgresql/data",
        ]
      }

      template {
        data = <<EOH
POSTGRES_USER=authentik
POSTGRES_DB=authentik
POSTGRES_PASSWORD={{ file "/srv/gluster/nomad-data/authentik/.postgres_password" }}
EOH
        destination = "secrets/postgres.env"
        env         = true
      }

      resources {
        cpu    = 200
        memory = 512
      }

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }
    }

    # Redis - Cache and message broker
    task "redis" {
      driver = "docker"

      volume_mount {
        volume      = "authentik-data"
        destination = "/data"
      }

      config {
        image        = "redis:7-alpine"
        network_mode = "host"
        args = [
          "--save", "60", "1",
          "--loglevel", "warning",
        ]
        volumes = [
          "/srv/gluster/nomad-data/authentik/redis:/data",
        ]
      }

      resources {
        cpu    = 100
        memory = 128
      }

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }
    }

    # Authentik Server - Web UI, API, and authentication endpoints
    task "server" {
      driver = "docker"

      volume_mount {
        volume      = "authentik-data"
        destination = "/data"
      }

      config {
        image        = "ghcr.io/goauthentik/server:2024.10"
        network_mode = "host"
        args         = ["server"]
        volumes = [
          "/srv/gluster/nomad-data/authentik/media:/media",
          "/srv/gluster/nomad-data/authentik/templates:/templates",
        ]
      }

      template {
        data = <<EOH
AUTHENTIK_SECRET_KEY={{ file "/srv/gluster/nomad-data/authentik/.secret_key" }}
AUTHENTIK_POSTGRESQL__HOST=127.0.0.1
AUTHENTIK_POSTGRESQL__PORT=5432
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_POSTGRESQL__PASSWORD={{ file "/srv/gluster/nomad-data/authentik/.postgres_password" }}
AUTHENTIK_REDIS__HOST=127.0.0.1
AUTHENTIK_REDIS__PORT=6379
AUTHENTIK_ERROR_REPORTING__ENABLED=false
AUTHENTIK_LISTEN__HTTP=0.0.0.0:9000
AUTHENTIK_LISTEN__HTTPS=0.0.0.0:9443
EOH
        destination = "secrets/authentik.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "authentik"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.authentik.rule=Host(`auth.${DNS_POSTFIX}`)",
          "traefik.http.routers.authentik.entrypoints=websecure",
          "traefik.http.routers.authentik.tls=true",
          "traefik.http.routers.authentik.tls.certresolver=step-ca",
          "traefik.http.services.authentik.loadbalancer.server.port=9000",
        ]

        check {
          type     = "http"
          path     = "/-/health/live/"
          port     = "http"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }

    # Authentik Worker - Background task processing
    task "worker" {
      driver = "docker"

      volume_mount {
        volume      = "authentik-data"
        destination = "/data"
      }

      config {
        image        = "ghcr.io/goauthentik/server:2024.10"
        network_mode = "host"
        args         = ["worker"]
        volumes = [
          "/srv/gluster/nomad-data/authentik/media:/media",
          "/srv/gluster/nomad-data/authentik/certs:/certs",
        ]
      }

      template {
        data = <<EOH
AUTHENTIK_SECRET_KEY={{ file "/srv/gluster/nomad-data/authentik/.secret_key" }}
AUTHENTIK_POSTGRESQL__HOST=127.0.0.1
AUTHENTIK_POSTGRESQL__PORT=5432
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_POSTGRESQL__PASSWORD={{ file "/srv/gluster/nomad-data/authentik/.postgres_password" }}
AUTHENTIK_REDIS__HOST=127.0.0.1
AUTHENTIK_REDIS__PORT=6379
AUTHENTIK_ERROR_REPORTING__ENABLED=false
EOH
        destination = "secrets/authentik.env"
        env         = true
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }
  }
}
