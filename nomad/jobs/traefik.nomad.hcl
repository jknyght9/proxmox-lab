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

    task "traefik" {
      driver = "docker"

      # Pull the root CA directly from Vault PKI via Workload Identity.
      # Vault is the single source of truth; no bind-mounted copies.
      vault {
        role = "traefik"
      }

      volume_mount {
        volume      = "traefik-data"
        destination = "/data"
      }

      template {
        data = <<EOH
{{ with secret "pki/cert/ca" }}{{ .Data.certificate }}{{ end }}
EOH
        destination = "local/root_ca.crt"
        change_mode = "restart"
      }

      env {
        # Trust the internal CA for ACME requests (rendered from Vault)
        SSL_CERT_FILE        = "${NOMAD_TASK_DIR}/root_ca.crt"
        LEGO_CA_CERTIFICATES = "${NOMAD_TASK_DIR}/root_ca.crt"
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
          "--certificatesresolvers.vault-pki.acme.email=admin@${DNS_POSTFIX}",
          "--certificatesresolvers.vault-pki.acme.storage=/data/traefik/acme.json",
          # ACME client talks to Vault directly on its HTTP API to avoid
          # the Traefik -> Traefik bootstrap loop. URL is rendered at deploy
          # time from hosts.json (nomad01 IP).
          "--certificatesresolvers.vault-pki.acme.caserver=${VAULT_ACME_URL}",
          "--certificatesresolvers.vault-pki.acme.httpchallenge=true",
          "--certificatesresolvers.vault-pki.acme.httpchallenge.entrypoint=web",
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
