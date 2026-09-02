# =============================================================================
# unifi-dns — UniFi local-DNS management app (github.com/jknyght9/unifi-dns)
# Topology (from upstream docker-compose.yml):
#   db       postgres:18-alpine        (published)
#   backend  FastAPI  :8000            (BUILT from ./backend — must be published
#                                       to a registry Nomad can pull; see
#                                       docs/unifi-dns-integration.md "Image gate")
#   frontend nginx SPA :80             (BUILT from ./frontend; reverse-proxies
#                                       /api/ -> backend. Under host networking we
#                                       override the upstream to 127.0.0.1:8000.)
#
# Ingress: only the frontend is exposed via Traefik (unifi-dns.<postfix>).
# The backend is internal-only (reached via the frontend nginx /api proxy).
#
# NOTE (v1 scaffold): node pin + host ports below must be confirmed against the
# live cluster at deploy time (avoid Postgres/HTTP port collisions with netbox
# on nomad03, authentik on nomad01, Traefik :8081 on all nodes).
# =============================================================================
job "unifi-dns" {
  datacenters = ["dc1"]
  type        = "service"

  group "unifi-dns" {
    count = 1

    # Pin for stable DNS + a single Postgres writer. Confirm free ports here.
    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    # First run builds the schema (alembic) — allow migration headroom.
    update {
      min_healthy_time  = "20s"
      healthy_deadline  = "8m"
      progress_deadline = "12m"
    }

    vault {
      role        = "unifi-dns"
      change_mode = "restart"
    }

    network {
      mode = "host"
      port "http"     { static = 8095 } # frontend (Traefik target)
      port "backend"  { static = 8000 } # internal API (not exposed)
      port "postgres" { static = 5434 } # unique vs other PG instances
    }

    # Postgres data on a node-local path (job is pinned to nomad01). unifi-dns's
    # DB holds audit/changeset/session state, NOT the authoritative DNS records
    # (those live in UniFi), so node-local is acceptable and avoids the
    # decommissioned gluster volume. CSI/NFS (like netbox) is a future upgrade.

    # --- Postgres 18 ---
    task "postgres" {
      driver = "docker"
      user   = "root"
      kill_timeout = "60s"

      config {
        image        = "postgres:18-alpine"
        network_mode = "host"
        volumes      = ["/opt/unifi-dns/postgres:/var/lib/postgresql"]
      }

      template {
        data = <<EOH
POSTGRES_USER=unifidns
POSTGRES_DB=unifidns
{{ with secret "secret/data/unifi-dns" }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
PGPORT=5434
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

    # --- Backend (FastAPI) — internal only ---
    task "backend" {
      driver = "docker"

      config {
        image        = "${unifi_dns_backend_image}"
        network_mode = "host"
        force_pull   = true # :latest tag — pull rebuilt image on each placement
      }

      # Internal root CA so OIDC discovery against auth.<postfix> validates TLS.
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
{{ with secret "secret/data/unifi-dns" }}
DATABASE_URL=postgresql+asyncpg://unifidns:{{ .Data.data.postgres_password }}@127.0.0.1:5434/unifidns
SESSION_SECRET={{ .Data.data.session_secret }}
{{ end }}
{{ with secret "secret/data/unifi-dns-oidc" }}
OIDC_ISSUER={{ .Data.data.oidc_endpoint }}
OIDC_CLIENT_ID={{ .Data.data.oidc_client_id }}
OIDC_CLIENT_SECRET={{ .Data.data.oidc_client_secret }}
{{ end }}
OIDC_REDIRECT_URL=https://unifi-dns.${dns_postfix}/api/auth/callback
{{ with secret "secret/data/unifi" }}
UNIFI_API_KEY={{ .Data.data.api_key }}
{{ end }}
UNIFI_HOST=https://${unifi_address}
UNIFI_SITE=${unifi_site}
UNIFI_VERIFY_TLS=false
CORS_ORIGINS='["https://unifi-dns.${dns_postfix}"]'
# Trust internal CA (Python httpx/requests)
REQUESTS_CA_BUNDLE=/local/certs/root_ca.crt
SSL_CERT_FILE=/local/certs/root_ca.crt
EOH
        destination = "secrets/backend.env"
        env         = true
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }

    # --- Frontend (nginx SPA + /api proxy) ---
    task "frontend" {
      driver = "docker"

      config {
        image        = "${unifi_dns_frontend_image}"
        network_mode = "host"
        volumes      = ["local/default.conf:/etc/nginx/conf.d/default.conf:ro"]
        force_pull   = true # :latest tag — pull rebuilt image on each placement
      }

      # Override the upstream's `backend:8000` (compose DNS) with 127.0.0.1:8000
      # since all tasks share the host netns. Listen on 8095 for Traefik.
      template {
        data = <<NGINX
server {
    listen 8095;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $${host};
        proxy_set_header X-Real-IP $${remote_addr};
        proxy_set_header X-Forwarded-For $${proxy_add_x_forwarded_for};
        proxy_set_header X-Forwarded-Proto $${scheme};
    }

    location / {
        try_files $${uri} $${uri}/ /index.html;
    }
}
NGINX
        destination = "local/default.conf"
      }

      service {
        name     = "unifi-dns"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.unifi-dns.rule=Host(`unifi-dns.${dns_postfix}`) || Host(`unifi-dns`)",
          "traefik.http.routers.unifi-dns.entrypoints=websecure",
          "traefik.http.routers.unifi-dns.tls=true",
          "traefik.http.services.unifi-dns.loadbalancer.server.port=8095",
        ]

        check {
          type     = "http"
          path     = "/"
          port     = "http"
          interval = "30s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
