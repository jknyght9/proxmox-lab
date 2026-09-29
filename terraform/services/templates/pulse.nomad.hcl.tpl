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

      template {
        data = <<EOH
TZ=UTC
PULSE_DEPLOYMENT_METHOD=nomad
PULSE_DATA_DIR=/data
PULSE_PUBLIC_URL=https://pulse.${dns_postfix}
PULSE_AUTH_USER=admin
{{ with secret "secret/data/pulse" }}
PULSE_AUTH_PASS={{ .Data.data.admin_password }}
{{ end }}
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
