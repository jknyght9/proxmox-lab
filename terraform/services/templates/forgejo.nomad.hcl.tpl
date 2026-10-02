# =============================================================================
# Forgejo — self-hosted Git hosting + Forgejo Actions (CI)
#
# Mirrors the netbox pattern: a Postgres sidecar (prestart) plus the app task,
# both pinned to a single node, state on CSI/NFS volumes (snapshotted on the
# cluster_state NAS), secrets via Vault WIF, HTTP fronted by Traefik with a
# Vault-PKI wildcard cert, and the internal root CA mounted so Forgejo trusts
# internal HTTPS (OIDC discovery against auth.<postfix>).
#
# Pinned to nomad03 (same node as netbox). Host networking is used, so every
# static port here must stay clear of the other services co-located on nomad03
# (netbox: http 8080, pg 5433, redis 6380, unit-status 8082). Forgejo therefore
# uses http 3000, git-ssh 2222 and pg 5435.
#
# NOTE (image tag): the integration brief specified codeberg.org/forgejo/forgejo:11,
# but verification against codeberg.org (2026-10-02) shows the current stable
# major is 16.x (latest 16.0.5, 2026-09-17) — the 11.x line is superseded.
# Per the brief's primary directive ("pin the current stable major; verify the
# tag exists") this pins the rolling `16` major tag. Change to `:11` or another
# line here if you specifically want the older LTS.
#
# NOTE (OIDC, Phase 2b — deferred): the Authentik OIDC *provider/application* is
# created by authentik-apps.tf and its client_secret written to
# secret/forgejo-oidc. The Forgejo-side authentication source is NOT configured
# here — it is created post-deploy with:
#   forgejo admin auth add-oauth --name authentik --provider openidConnect \
#     --key forgejo --secret <secret/forgejo-oidc> \
#     --auto-discover-url https://auth.<postfix>/application/o/forgejo/.well-known/openid-configuration
# The redirect URI registered in Authentik is
#   https://git.<postfix>/user/oauth2/authentik/callback
# which matches Forgejo's /user/oauth2/<AuthName>/callback convention for the
# auth source named "authentik".
# =============================================================================
job "forgejo" {
  datacenters = ["dc1"]
  type        = "service"

  group "forgejo" {
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
      role        = "forgejo"
      change_mode = "restart"
    }

    network {
      mode = "host"
      port "http"     { static = 3000 }
      port "ssh"      { static = 2222 }
      port "postgres" { static = 5435 }
    }

    # State lives on the cluster_state NAS via CSI/NFS — two datasets:
    # Postgres data (16K recordsize) and the Forgejo data dir (/data — repos,
    # LFS, attachments, actions artifacts). Both snapshotted on TrueNAS.
    volume "pg" {
      type            = "csi"
      source          = "forgejo-pg-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
    volume "data" {
      type            = "csi"
      source          = "forgejo-data-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    # PostgreSQL — primary database
    task "postgres" {
      driver = "docker"
      user   = "root"

      # Give postgres a full minute to flush WAL on shutdown — same reasoning
      # as the netbox/authentik postgres tasks; default 5s is tight.
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
POSTGRES_USER=forgejo
POSTGRES_DB=forgejo
{{ with secret "secret/data/forgejo" }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
PGDATA=/var/lib/postgresql/data
PGPORT=5435
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

    # Forgejo — web UI, API, git-over-SSH (built-in SSH server) and Actions.
    task "forgejo" {
      driver = "docker"

      config {
        image        = "codeberg.org/forgejo/forgejo:16.0.5"
        network_mode = "host"
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
        read_only   = false
      }

      # Root CA cert pulled from Vault at template-render time so Forgejo
      # (Go net/http, respects SSL_CERT_FILE) trusts internal HTTPS when it
      # talks to auth.<postfix> for OIDC discovery. git uses GIT_SSL_CAINFO.
      template {
        data        = <<EOH
{{ with secret "pki/cert/ca" }}{{ .Data.certificate }}{{ end }}
EOH
        destination = "local/certs/root_ca.crt"
        perms       = "0644"
        change_mode = "noop"
      }

      # Forgejo configuration via FORGEJO__<section>__<KEY> env vars (written
      # to app.ini on first start; INSTALL_LOCK skips the web installer).
      template {
        data = <<EOH
{{ with secret "secret/data/forgejo" }}
FORGEJO__database__PASSWD={{ .Data.data.postgres_password }}
{{ end }}
# --- General ---
FORGEJO__security__INSTALL_LOCK=true
FORGEJO__service__DISABLE_REGISTRATION=true
FORGEJO__actions__ENABLED=true
# Distinct cookie names (per brief) so a shared parent domain can't collide
FORGEJO__session__COOKIE_NAME=forgejo_session
FORGEJO__security__CSRF_COOKIE_NAME=forgejo_csrf
# --- Database (Postgres sidecar on the host netns) ---
FORGEJO__database__DB_TYPE=postgres
FORGEJO__database__HOST=127.0.0.1:5435
FORGEJO__database__NAME=forgejo
FORGEJO__database__USER=forgejo
# --- Server / HTTP ---
FORGEJO__server__PROTOCOL=http
FORGEJO__server__HTTP_ADDR=0.0.0.0
FORGEJO__server__HTTP_PORT=3000
FORGEJO__server__DOMAIN=git.${dns_postfix}
FORGEJO__server__ROOT_URL=https://git.${dns_postfix}/
# --- Git over SSH (built-in Go SSH server, host port 2222) ---
FORGEJO__server__START_SSH_SERVER=true
FORGEJO__server__SSH_DOMAIN=git.${dns_postfix}
FORGEJO__server__SSH_PORT=2222
FORGEJO__server__SSH_LISTEN_PORT=2222
# --- Trust internal CA for OIDC discovery / outbound HTTPS ---
SSL_CERT_FILE=/local/certs/root_ca.crt
GIT_SSL_CAINFO=/local/certs/root_ca.crt
EOH
        destination = "secrets/forgejo.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "forgejo"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.forgejo.rule=Host(`git.${dns_postfix}`) || Host(`git`)",
          "traefik.http.routers.forgejo.entrypoints=websecure",
          "traefik.http.routers.forgejo.tls=true",
          "traefik.http.services.forgejo.loadbalancer.server.port=3000",
        ]

        check {
          type     = "http"
          path     = "/api/healthz"
          port     = "http"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
