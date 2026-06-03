job "netbox" {
  datacenters = ["dc1"]
  type        = "service"

  group "netbox" {
    count = 1

    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad03"
    }

    # Allow extra time for first-run migrations
    update {
      min_healthy_time  = "30s"
      healthy_deadline  = "10m"
      progress_deadline = "15m"
    }

    vault {
      role        = "netbox"
      change_mode = "restart"
    }

    network {
      mode = "host"
      port "http"     { static = 8080 }
      port "postgres" { static = 5433 }
      port "redis"    { static = 6380 }
    }

    # State lives on the cluster_state NAS via CSI/NFS — three datasets:
    # postgres data (16K recordsize), Redis AOF, and the server/worker/
    # housekeeping shared media dir. Root CA cert for OIDC discovery is
    # fetched from Vault PKI by a template stanza in the server task
    # (the only one that needs it).
    volume "pg" {
      type            = "csi"
      source          = "netbox-pg-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
    volume "redis" {
      type            = "csi"
      source          = "netbox-redis-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
    volume "data" {
      type            = "csi"
      source          = "netbox-data-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    # PostgreSQL — primary database
    task "postgres" {
      driver = "docker"
      user   = "root"

      # Give postgres a full minute to flush WAL on shutdown — same
      # reasoning as the authentik postgres task; default 5s is tight.
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
POSTGRES_USER=netbox
POSTGRES_DB=netbox
{{ with secret "secret/data/netbox" }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
PGDATA=/var/lib/postgresql/data
PGPORT=5433
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

    # Redis — caching and task queue
    task "redis" {
      driver = "docker"

      config {
        image        = "redis:8-alpine"
        network_mode = "host"
        args         = ["--port", "6380", "--appendonly", "yes"]
      }

      volume_mount {
        volume      = "redis"
        destination = "/data"
        read_only   = false
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

    # Netbox Server — web UI and API
    # Port 8081 conflicts with Traefik dashboard — override NGINX Unit config
    # to use 8082 for static files instead
    task "server" {
      driver = "docker"

      config {
        image        = "netboxcommunity/netbox:v4.5.8"
        network_mode = "host"
        volumes = [
          "local/nginx-unit.json:/etc/unit/nginx-unit.json:ro",
          "local/extra.py:/etc/netbox/config/extra.py:ro",
        ]
      }

      volume_mount {
        volume      = "data"
        destination = "/opt/netbox/netbox/media"
        read_only   = false
      }

      # Root CA cert pulled from Vault at template-render time. Replaces
      # the gluster /srv/gluster/nomad-data/certs:/certs:ro bind-mount.
      # Used by REQUESTS_CA_BUNDLE / SSL_CERT_FILE for OIDC discovery
      # against auth.<domain>.
      template {
        data        = <<EOH
{{ with secret "pki/cert/ca" }}{{ .Data.certificate }}{{ end }}
EOH
        destination = "local/certs/root_ca.crt"
        perms       = "0644"
        change_mode = "noop"
      }

      # Custom NGINX Unit config — changes status port from 8081 (Traefik conflict) to 8082
      template {
        data = <<UNITCFG
{"listeners":{"0.0.0.0:8080":{"pass":"routes/main","forwarded":{"client_ip":"X-Forwarded-For","protocol":"X-Forwarded-Proto","source":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"]}},"0.0.0.0:8082":{"pass":"routes/status","forwarded":{"client_ip":"X-Forwarded-For","protocol":"X-Forwarded-Proto","source":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"]}}},"routes":{"main":[{"match":{"uri":"/static/*"},"action":{"share":"/opt/netbox/netbox$${uri}"}},{"action":{"pass":"applications/netbox"}}],"status":[{"match":{"uri":"/status/*"},"action":{"proxy":"http://unix:/opt/unit/unit.sock"}}]},"applications":{"netbox":{"type":"python 3","path":"/opt/netbox/netbox/","module":"netbox.wsgi","home":"/opt/netbox/venv","processes":{"max":4,"spare":1,"idle_timeout":120}}},"access_log":"/dev/stdout"}
UNITCFG
        destination = "local/nginx-unit.json"
      }

      template {
        data = <<EOH
{{ with secret "secret/data/netbox" }}
DB_PASSWORD={{ .Data.data.postgres_password }}
SECRET_KEY={{ .Data.data.secret_key }}
SUPERUSER_PASSWORD={{ .Data.data.admin_password }}
SUPERUSER_EMAIL={{ .Data.data.admin_email }}
SUPERUSER_API_TOKEN={{ .Data.data.api_token }}
{{ end }}
DB_HOST=127.0.0.1
DB_PORT=5433
DB_USER=netbox
DB_NAME=netbox
REDIS_HOST=127.0.0.1
REDIS_PORT=6380
REDIS_CACHE_HOST=127.0.0.1
REDIS_CACHE_PORT=6380
ALLOWED_HOSTS=*
CSRF_TRUSTED_ORIGINS=https://netbox.${dns_postfix}
SUPERUSER_NAME=admin
REMOTE_AUTH_ENABLED=True
REMOTE_AUTH_BACKEND=social_core.backends.open_id_connect.OpenIdConnectAuth
# Trust internal CA for OIDC discovery
REQUESTS_CA_BUNDLE=/local/certs/root_ca.crt
SSL_CERT_FILE=/local/certs/root_ca.crt
EOH
        destination = "secrets/netbox.env"
        env         = true
      }

      # OIDC SSO configuration — reads from separate Vault path (not managed by Terraform)
      template {
        data = <<SSOCFG
{{ with secret "secret/data/netbox" }}
# API token peppers required for Netbox v4.5+ v2 tokens
API_TOKEN_PEPPERS = {1: "{{ .Data.data.secret_key }}"}
{{ end }}

{{ with secret "secret/data/netbox-oidc" }}
SOCIAL_AUTH_OIDC_OIDC_ENDPOINT = "{{ .Data.data.oidc_endpoint }}"
SOCIAL_AUTH_OIDC_KEY = "{{ .Data.data.oidc_client_id }}"
SOCIAL_AUTH_OIDC_SECRET = "{{ .Data.data.oidc_client_secret }}"
{{ end }}

SOCIAL_AUTH_OIDC_SCOPE = ["openid", "profile", "email"]
SOCIAL_AUTH_OIDC_USERNAME_KEY = "preferred_username"

# Auto-create SSO users
REMOTE_AUTH_AUTO_CREATE_USER = True
REMOTE_AUTH_DEFAULT_GROUPS = []
REMOTE_AUTH_DEFAULT_PERMISSIONS = {}
# REMOTE_AUTH_STAFF_SUPERUSERS only applies to header-based remote auth,
# not the social-auth OIDC backend we use for Authentik. Promote OIDC
# users to staff + superuser via a Django signal instead — every user
# who reaches Authentik has already passed its access policies, so they
# get full Netbox access in the lab. Tighten by checking group claims
# here if you want role separation later.
REMOTE_AUTH_STAFF_SUPERUSERS = True

from django.contrib.auth.signals import user_logged_in
from django.dispatch import receiver

@receiver(user_logged_in)
def _promote_sso_users_to_superuser(sender, request, user, **kwargs):
    # Netbox 4.5's custom User model treats is_staff as a non-concrete
    # field (it's derived from group membership / is_superuser), so we
    # can't pass it to save(update_fields=...). is_superuser alone is
    # enough for full UI access.
    if not user.is_superuser and request.path.startswith("/oauth/"):
        user.is_superuser = True
        user.save(update_fields=["is_superuser"])

# Display on login page
SOCIAL_AUTH_BACKEND_ATTRS = {
    "oidc": ("Sign in with Authentik", "login"),
}
SSOCFG
        destination = "local/extra.py"
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "netbox"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.netbox.rule=Host(`netbox.${dns_postfix}`) || Host(`netbox`)",
          "traefik.http.routers.netbox.entrypoints=websecure",
          "traefik.http.routers.netbox.tls=true",
          "traefik.http.services.netbox.loadbalancer.server.port=8080",
        ]

        check {
          type     = "http"
          path     = "/login/"
          port     = "http"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }

    # Netbox Worker — background task processing
    # Waits for server health check before starting (migrations must complete first)
    task "worker" {
      driver = "docker"

      config {
        image        = "netboxcommunity/netbox:v4.5.8"
        network_mode = "host"
        entrypoint   = ["/usr/bin/bash", "-c"]
        args         = ["echo 'Waiting for Netbox server...'; while ! curl -sf http://127.0.0.1:8080/login/ >/dev/null 2>&1; do sleep 5; done; echo 'Server ready, starting worker'; /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py rqworker"]
      }

      volume_mount {
        volume      = "data"
        destination = "/opt/netbox/netbox/media"
        read_only   = false
      }

      template {
        data = <<EOH
{{ with secret "secret/data/netbox" }}
DB_PASSWORD={{ .Data.data.postgres_password }}
SECRET_KEY={{ .Data.data.secret_key }}
{{ end }}
DB_HOST=127.0.0.1
DB_PORT=5433
DB_USER=netbox
DB_NAME=netbox
REDIS_HOST=127.0.0.1
REDIS_PORT=6380
REDIS_CACHE_HOST=127.0.0.1
REDIS_CACHE_PORT=6380
EOH
        destination = "secrets/netbox.env"
        env         = true
      }

      resources {
        cpu    = 200
        memory = 512
      }
    }

    # Netbox Housekeeping — periodic cleanup (runs every hour in a loop)
    # Waits for server health check before starting (migrations must complete first)
    task "housekeeping" {
      driver = "docker"

      config {
        image        = "netboxcommunity/netbox:v4.5.8"
        network_mode = "host"
        entrypoint   = ["/usr/bin/bash", "-c"]
        args         = ["echo 'Waiting for Netbox server...'; while ! curl -sf http://127.0.0.1:8080/login/ >/dev/null 2>&1; do sleep 5; done; echo 'Server ready, starting housekeeping'; while true; do /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py housekeeping; sleep 3600; done"]
      }

      volume_mount {
        volume      = "data"
        destination = "/opt/netbox/netbox/media"
        read_only   = false
      }

      template {
        data = <<EOH
{{ with secret "secret/data/netbox" }}
DB_PASSWORD={{ .Data.data.postgres_password }}
SECRET_KEY={{ .Data.data.secret_key }}
{{ end }}
DB_HOST=127.0.0.1
DB_PORT=5433
DB_USER=netbox
DB_NAME=netbox
REDIS_HOST=127.0.0.1
REDIS_PORT=6380
REDIS_CACHE_HOST=127.0.0.1
REDIS_CACHE_PORT=6380
EOH
        destination = "secrets/netbox.env"
        env         = true
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }
  }
}
