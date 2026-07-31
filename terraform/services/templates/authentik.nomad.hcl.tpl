job "authentik" {
  datacenters = ["dc1"]
  type        = "service"

  group "authentik" {
    count = 1

    # Pin to same node as Traefik for consistency
    constraint {
      attribute = "$${attr.unique.hostname}"
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

    # State lives on the cluster_state NAS via CSI/NFS. The lab's root
    # CA cert (previously bind-mounted from /srv/gluster/nomad-data/certs)
    # is now fetched per-task from Vault's PKI mount at template-render
    # time — see the server + worker template stanzas below.
    volume "pg" {
      type            = "csi"
      source          = "authentik-pg-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
    volume "data" {
      type            = "csi"
      source          = "authentik-data-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    # PostgreSQL - Database for Authentik
    # Note: As of 2025.10, Authentik no longer uses Redis - everything runs through PostgreSQL
    task "postgres" {
      driver = "docker"

      user = "root"

      # Postgres needs more than the default 5s to flush WAL + close
      # connections on shutdown. Without this we risk dirty shutdowns
      # that postgres recovers from, but slowly, on next start.
      kill_timeout = "60s"

      config {
        image        = "postgres:17"
        network_mode = "host"
      }

      volume_mount {
        volume      = "pg"
        destination = "/var/lib/postgresql/data"
        read_only   = false
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
        image        = "ghcr.io/goauthentik/server:2026.2.2"
        network_mode = "host"
        args         = ["server"]
        # Custom branding (disabled — uncomment after placing files in
        # the authentik-data NFS share's branding/ subdir):
        # volumes = [
        #   "/path-on-host/branding/background.png:/web/dist/assets/images/flow_background.jpg:ro",
        # ]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
        read_only   = false
      }

      # Root CA cert pulled from Vault at template-render time. Replaces
      # the gluster /srv/gluster/nomad-data/certs:/certs bind-mount.
      # Authentik reads this via REQUESTS_CA_BUNDLE / SSL_CERT_FILE.
      template {
        data        = <<EOH
{{ with secret "pki/cert/ca" }}{{ .Data.certificate }}{{ end }}
EOH
        destination = "local/certs/root_ca.crt"
        perms       = "0644"
        change_mode = "noop"
      }

      template {
        data = <<EOH
{{ with secret "secret/data/authentik" }}
AUTHENTIK_SECRET_KEY={{ .Data.data.secret_key }}
AUTHENTIK_POSTGRESQL__PASSWORD={{ .Data.data.postgres_password }}
AUTHENTIK_BOOTSTRAP_PASSWORD={{ .Data.data.admin_password }}
AUTHENTIK_BOOTSTRAP_EMAIL={{ .Data.data.admin_email }}
AUTHENTIK_BOOTSTRAP_TOKEN={{ .Data.data.api_token }}
{{ end }}
AUTHENTIK_HOST=https://auth.${dns_postfix}
AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8
AUTHENTIK_POSTGRESQL__HOST=127.0.0.1
AUTHENTIK_POSTGRESQL__PORT=5432
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_ERROR_REPORTING__ENABLED=false
AUTHENTIK_LISTEN__HTTP=0.0.0.0:9000
AUTHENTIK_LISTEN__HTTPS=0.0.0.0:9443
# NB: do NOT set AUTHENTIK_STORAGE__MEDIA__FILE__PATH — it overrides the *base*
# data dir (default /data), and the file backend appends media/public/ itself.
# Leave it unset so uploaded/branding media resolves to /data/media/public/
# (served at /files/media/public/<f>?token=... since 2025.12; /media/ is gone).
# Trust internal CA for HTTPS requests — file lives in the alloc-local
# /local/certs dir, populated by the template stanza above. Nomad's
# docker driver mounts /local/ into the container automatically.
REQUESTS_CA_BUNDLE=/local/certs/root_ca.crt
SSL_CERT_FILE=/local/certs/root_ca.crt
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
          "traefik.http.routers.authentik-http.rule=Host(`auth.${dns_postfix}`) || Host(`auth`)",
          "traefik.http.routers.authentik-http.entrypoints=web",
          # HTTPS router with TLS - accepts both FQDN and short name
          "traefik.http.routers.authentik.rule=Host(`auth.${dns_postfix}`) || Host(`auth`)",
          "traefik.http.routers.authentik.entrypoints=websecure",
          "traefik.http.routers.authentik.tls=true",
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
        image        = "ghcr.io/goauthentik/server:2026.2.2"
        network_mode = "host"
        args         = ["worker"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
        read_only   = false
      }

      # Root CA cert via Vault PKI — same pattern as server task above.
      template {
        data        = <<EOH
{{ with secret "pki/cert/ca" }}{{ .Data.certificate }}{{ end }}
EOH
        destination = "local/certs/root_ca.crt"
        perms       = "0644"
        change_mode = "noop"
      }

      template {
        data = <<EOH
{{ with secret "secret/data/authentik" }}
AUTHENTIK_SECRET_KEY={{ .Data.data.secret_key }}
AUTHENTIK_POSTGRESQL__PASSWORD={{ .Data.data.postgres_password }}
AUTHENTIK_BOOTSTRAP_PASSWORD={{ .Data.data.admin_password }}
AUTHENTIK_BOOTSTRAP_EMAIL={{ .Data.data.admin_email }}
AUTHENTIK_BOOTSTRAP_TOKEN={{ .Data.data.api_token }}
{{ end }}
AUTHENTIK_HOST=https://auth.${dns_postfix}
AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8
AUTHENTIK_POSTGRESQL__HOST=127.0.0.1
AUTHENTIK_POSTGRESQL__PORT=5432
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_ERROR_REPORTING__ENABLED=false
# NB: AUTHENTIK_STORAGE__MEDIA__FILE__PATH intentionally unset (see server task).
# Trust internal CA for HTTPS requests
REQUESTS_CA_BUNDLE=/local/certs/root_ca.crt
SSL_CERT_FILE=/local/certs/root_ca.crt
EOH
        destination = "secrets/authentik.env"
        env         = true
      }

      resources {
        cpu    = 300
        memory = 1024
      }
    }
  }
}
