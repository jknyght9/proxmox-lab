job "authentik" {
  datacenters = ["dc1"]
  type        = "service"

  group "authentik" {
    count = 1

    # Pin to same node as Traefik for consistency
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }

    # Vault integration - fetch secrets at runtime using Workload Identity
    vault {
      role        = "authentik"
      change_mode = "restart"
    }

    network {
      mode = "host"
      port "http"     { static = 9000 }
      port "https"    { static = 9443 }
      port "postgres" { static = 5432 }
    }

    # PostgreSQL - Database for Authentik
    # Note: As of 2025.10, Authentik no longer uses Redis - everything runs through PostgreSQL
    task "postgres" {
      driver = "docker"

      user = "root"

      config {
        image        = "postgres:16"
        network_mode = "host"
        volumes = [
          "/srv/gluster/nomad-data/authentik/postgres:/var/lib/postgresql/data",
        ]
      }

      template {
        data = <<EOH
POSTGRES_USER=authentik
POSTGRES_DB=authentik
{{ with secret "secret/data/authentik" }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
PGDATA=/var/lib/postgresql/data
# Increase max connections for Authentik 2025.10+ (no Redis means more DB connections)
POSTGRES_INITDB_ARGS=--encoding=UTF8
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

    # Authentik Server - Web UI, API, and authentication endpoints
    task "server" {
      driver = "docker"

      config {
        image        = "ghcr.io/goauthentik/server:2026.2"
        network_mode = "host"
        args         = ["server"]
        volumes = [
          "/srv/gluster/nomad-data/authentik/data:/data",
        ]
      }

      template {
        data = <<EOH
{{ with secret "secret/data/authentik" }}
AUTHENTIK_SECRET_KEY={{ .Data.data.secret_key }}
AUTHENTIK_POSTGRESQL__PASSWORD={{ .Data.data.postgres_password }}
AUTHENTIK_BOOTSTRAP_PASSWORD={{ .Data.data.admin_password }}
AUTHENTIK_BOOTSTRAP_EMAIL={{ .Data.data.admin_email }}
{{ end }}
AUTHENTIK_POSTGRESQL__HOST=127.0.0.1
AUTHENTIK_POSTGRESQL__PORT=5432
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
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
          # HTTP router for ACME challenges and short name
          "traefik.http.routers.authentik-http.rule=Host(`auth.${DNS_POSTFIX}`) || Host(`auth`)",
          "traefik.http.routers.authentik-http.entrypoints=web",
          # HTTPS router with TLS - accepts both FQDN and short name
          "traefik.http.routers.authentik.rule=Host(`auth.${DNS_POSTFIX}`) || Host(`auth`)",
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

      config {
        image        = "ghcr.io/goauthentik/server:2026.2"
        network_mode = "host"
        args         = ["worker"]
        volumes = [
          "/srv/gluster/nomad-data/authentik/data:/data",
        ]
      }

      template {
        data = <<EOH
{{ with secret "secret/data/authentik" }}
AUTHENTIK_SECRET_KEY={{ .Data.data.secret_key }}
AUTHENTIK_POSTGRESQL__PASSWORD={{ .Data.data.postgres_password }}
AUTHENTIK_BOOTSTRAP_PASSWORD={{ .Data.data.admin_password }}
AUTHENTIK_BOOTSTRAP_EMAIL={{ .Data.data.admin_email }}
{{ end }}
AUTHENTIK_POSTGRESQL__HOST=127.0.0.1
AUTHENTIK_POSTGRESQL__PORT=5432
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
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
