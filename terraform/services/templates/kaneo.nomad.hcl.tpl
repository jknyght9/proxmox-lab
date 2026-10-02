# =============================================================================
# Kaneo — self-hosted project-management board (Kanban + projects + tasks)
#
# Mirrors the netbox/forgejo pattern: a Postgres sidecar (prestart) plus the
# single Kaneo app task (server+web in one container), both pinned to one node,
# Postgres state on a CSI/NFS volume (snapshotted on the cluster_state NAS),
# secrets via Vault WIF, HTTP fronted by Traefik with a Vault-PKI wildcard cert,
# and the internal root CA mounted so Kaneo (Node.js) trusts internal HTTPS when
# it fetches the Authentik OIDC discovery document.
#
# Pinned to nomad03 (same node as netbox + forgejo). Host networking is used, so
# every static port here must stay clear of the other services co-located on
# nomad03 (netbox: http 8080, pg 5433, redis 6380, unit-status 8082; forgejo:
# http 3000, ssh 2222, pg 5435). Kaneo therefore uses http 5173 and pg 5436
# (verified free on nomad03 at authoring time, 2026-10-02).
#
# Image pins (verified against upstream compose + release tags, 2026-10-02):
#   - postgres:16-alpine  (upstream uses 16, NOT 17 — match it)
#   - ghcr.io/usekaneo/kaneo:2.30.1  (latest release v2.30.1; container tag
#     drops the leading v). Pin the exact patch rather than a floating tag.
#
# NOTE (OIDC, two-phase): the Authentik OIDC provider/application is created by
# authentik-apps.tf and its client_secret written to secret/kaneo-oidc. The
# CUSTOM_OAUTH_* env block below is emitted ONLY once that secret's
# oidc_endpoint is populated (the {{ with }}{{ if }} guard) so the FIRST boot —
# which happens before authentik_apps runs — comes up cleanly without a
# half-configured OIDC provider. On the next apply (after Authentik is
# configured) the block renders and the job restarts via change_mode=restart.
#
# Kaneo links OIDC accounts by verified email only — there is NO group→role
# mapping. Workspace/project membership is granted MANUALLY in the Kaneo UI
# after a user's first SSO login.
# =============================================================================
job "kaneo" {
  datacenters = ["dc1"]
  type        = "service"

  group "kaneo" {
    count = 1

    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad03"
    }

    # Allow extra time for the image pull + first-run DB migrations.
    update {
      min_healthy_time  = "30s"
      healthy_deadline  = "10m"
      progress_deadline = "15m"
    }

    vault {
      role        = "kaneo"
      change_mode = "restart"
    }

    network {
      mode = "host"
      port "http"     { static = 5173 }
      port "postgres" { static = 5436 }
    }

    # State lives on the cluster_state NAS via CSI/NFS — just the Postgres data
    # (16K recordsize). The Kaneo app container holds no durable on-disk state.
    volume "pg" {
      type            = "csi"
      source          = "kaneo-pg-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    # PostgreSQL — primary database
    task "postgres" {
      driver = "docker"
      user   = "root"

      # Give postgres a full minute to flush WAL on shutdown — same reasoning
      # as the netbox/forgejo postgres tasks; default 5s is tight.
      kill_timeout = "60s"

      config {
        image        = "postgres:16-alpine"
        network_mode = "host"
      }

      volume_mount {
        volume      = "pg"
        destination = "/var/lib/postgresql/data"
        read_only   = false
      }

      template {
        data = <<EOH
POSTGRES_USER=kaneo
POSTGRES_DB=kaneo
{{ with secret "secret/data/kaneo" }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
PGDATA=/var/lib/postgresql/data
PGPORT=5436
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

    # Kaneo — combined server + web UI (single container), HTTP on :5173.
    task "kaneo" {
      driver = "docker"

      config {
        image        = "ghcr.io/usekaneo/kaneo:2.30.1"
        network_mode = "host"
      }

      # Root CA cert pulled from Vault at template-render time so Kaneo (Node.js,
      # respects NODE_EXTRA_CA_CERTS) trusts internal HTTPS when it fetches the
      # Authentik OIDC discovery document from auth.<postfix>.
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
KANEO_CLIENT_URL=https://tasks.${dns_postfix}
{{ with secret "secret/data/kaneo" }}
DATABASE_URL=postgresql://kaneo:{{ .Data.data.postgres_password }}@127.0.0.1:5436/kaneo
AUTH_SECRET={{ .Data.data.auth_secret }}
POSTGRES_USER=kaneo
POSTGRES_DB=kaneo
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
# Leave DISABLE_REGISTRATION false for the FIRST login so your OIDC account can
# be created. Flip to true after onboarding (set DISABLE_REGISTRATION=true here
# and redeploy) to lock the instance to existing/OIDC-linked accounts.
DISABLE_REGISTRATION=false
# Node trusts the internal CA via NODE_EXTRA_CA_CERTS (NOT SSL_CERT_FILE — Node
# does not honour that variable).
NODE_EXTRA_CA_CERTS=/local/certs/root_ca.crt
# --- Custom OIDC (Authentik) — emitted only once secret/kaneo-oidc is
#     populated by authentik-apps.tf, so first boot comes up without a
#     half-configured provider. ---
{{ with secret "secret/data/kaneo-oidc" }}{{ if .Data.data.oidc_endpoint }}
CUSTOM_OAUTH_CLIENT_ID=kaneo
CUSTOM_OAUTH_CLIENT_SECRET={{ .Data.data.oidc_client_secret }}
CUSTOM_OAUTH_DISCOVERY_URL=https://auth.${dns_postfix}/application/o/kaneo/.well-known/openid-configuration
CUSTOM_OAUTH_SCOPES=openid,profile,email
CUSTOM_AUTH_PKCE=true
{{ end }}{{ end }}
EOH
        destination = "secrets/kaneo.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "kaneo"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.kaneo.rule=Host(`tasks.${dns_postfix}`) || Host(`tasks`)",
          "traefik.http.routers.kaneo.entrypoints=websecure",
          "traefik.http.routers.kaneo.tls=true",
          "traefik.http.services.kaneo.loadbalancer.server.port=5173",
        ]

        check {
          type     = "http"
          path     = "/api/health"
          port     = "http"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
