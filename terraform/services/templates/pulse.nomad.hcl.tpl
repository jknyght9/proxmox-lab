# =============================================================================
# Pulse — Proxmox/PBS/TrueNAS monitoring (github.com/rcourtman/pulse)
#
# Single container. Agentless: it polls the Proxmox API with a read-only token.
# The token + web-login password come from Vault (secret/pulse), which the
# infra layer (terraform/pulse-monitoring.tf) populates.
#
# NOTE: Pulse configures its monitored nodes via the WEB UI, not env vars.
# After first deploy: log in (admin / secret/pulse:admin_password) at
# https://pulse.<postfix>, then Settings -> Infrastructure -> add the Proxmox
# node using the read-only token from `vault kv get secret/pulse` (pve_token_id
# + pve_token). One PVEAuditor token covers the whole cluster.
#
# Confirm the node pin + host port 7655 don't collide at deploy time.
# =============================================================================
job "pulse" {
  datacenters = ["dc1"]
  type        = "service"

  group "pulse" {
    count = 1

    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    update {
      min_healthy_time = "20s"
      healthy_deadline = "5m"
    }

    vault {
      role        = "pulse"
      change_mode = "restart"
    }

    network {
      mode = "host"
      port "http" { static = 7655 }
    }

    task "pulse" {
      driver = "docker"

      config {
        image        = "${pulse_image}"
        network_mode = "host"
        # Node-local persistence (pinned to nomad01). Holds Pulse's config,
        # added nodes, and its rolling metric history — non-authoritative, so
        # node-local is fine. CSI/NFS is a later durability upgrade.
        volumes = ["/opt/pulse/data:/data"]
      }

      # Root CA cert pulled from Vault PKI at render time so Pulse (Go) can
      # validate the OIDC issuer's HTTPS (auth.${dns_postfix}, served with the
      # internal PKI cert). Go's crypto/x509 honors SSL_CERT_FILE (set below).
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
TZ=UTC
PULSE_DEPLOYMENT_METHOD=nomad
PULSE_DATA_DIR=/data
PULSE_PUBLIC_URL=https://pulse.${dns_postfix}
# Local admin kept as break-glass. Set PULSE_AUTH_HIDE_LOCAL_LOGIN=true to force
# SSO-only once OIDC is verified.
PULSE_AUTH_USER=admin
{{ with secret "secret/data/pulse" }}
PULSE_AUTH_PASS={{ .Data.data.admin_password }}
{{ end }}
# --- Authentik OIDC (native single-provider). secret/pulse-oidc is populated by
# authentik-apps.tf after the provider/app is created; until then oidc_endpoint
# is empty and the OIDC_* vars are omitted so Pulse starts on local auth only.
# The vault{} change_mode=restart re-renders + restarts Pulse when it's filled.
{{ with secret "secret/data/pulse-oidc" }}{{ if .Data.data.oidc_endpoint }}
OIDC_ISSUER_URL={{ .Data.data.oidc_endpoint }}
OIDC_CLIENT_ID={{ .Data.data.oidc_client_id }}
OIDC_CLIENT_SECRET={{ .Data.data.oidc_client_secret }}
{{ end }}{{ end }}
# Trust the internal CA for the OIDC issuer's HTTPS. NOTE: this scopes Pulse's
# outbound TLS trust to the internal CA, so its GitHub update check may stop
# validating — acceptable tradeoff; revisit with a combined bundle if needed.
SSL_CERT_FILE=/local/certs/root_ca.crt
EOH
        destination = "secrets/pulse.env"
        env         = true
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "pulse"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.pulse.rule=Host(`pulse.${dns_postfix}`) || Host(`pulse`)",
          "traefik.http.routers.pulse.entrypoints=websecure",
          "traefik.http.routers.pulse.tls=true",
          "traefik.http.services.pulse.loadbalancer.server.port=7655",
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
