variable "vault_tls_enabled" {
  type        = bool
  default     = false
  description = "Enable TLS on Vault's API listener using cert issued by its own PKI (bootstrap: false on first deploy, true after initVaultPKI issues the listener cert)"
}

variable "dns_postfix" {
  type        = string
  description = "Domain suffix for service DNS (e.g., jdclabs.lan)"
}

job "vault" {
  datacenters = ["dc1"]
  type        = "service"

  group "vault" {
    count = 1

    # Pin to same node as Traefik for consistency
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }

    network {
      mode = "host"
      port "api"     { static = 8200 }
      port "cluster" { static = 8201 }
    }

    # Belt-and-suspenders: refuse to start if the gluster volume isn't
    # actually mounted (host-level RequiresMountsFor should already guarantee
    # this, but this catches manual-unmount and runtime-drop edge cases).
    task "wait-for-gluster" {
      driver = "raw_exec"
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      config {
        command = "/bin/bash"
        args = [
          "-c",
          "mountpoint -q /srv/gluster/nomad-data && test -f /srv/gluster/nomad-data/.mount-sentinel"
        ]
      }
      resources {
        cpu    = 10
        memory = 16
      }
    }

    task "vault" {
      driver = "docker"

      env {
        SKIP_CHOWN = "true"
        VAULT_ADDR = var.vault_tls_enabled ? "https://127.0.0.1:8200" : "http://127.0.0.1:8200"
        # Trust internal CA for OIDC discovery and self-TLS verification
        SSL_CERT_FILE = "/certs/root_ca.crt"
      }

      config {
        image        = "hashicorp/vault:1.21.4"
        network_mode = "host"
        privileged   = true
        args         = ["server", "-config=/local/vault.hcl"]
        volumes = [
          "/srv/gluster/nomad-data/vault:/data/vault",
          "/srv/gluster/nomad-data/certs:/certs:ro",
          "/srv/gluster/nomad-data/vault-tls:/tls:ro",
        ]
      }

      template {
        data = <<EOH
ui = true
disable_mlock = true

storage "file" {
  path = "/data/vault"
}

listener "tcp" {
  address = "0.0.0.0:8200"
%{ if var.vault_tls_enabled ~}
  tls_cert_file   = "/tls/cert.pem"
  tls_key_file    = "/tls/key.pem"
  tls_min_version = "tls12"
%{ else ~}
  tls_disable = true
%{ endif ~}
}

%{ if var.vault_tls_enabled ~}
api_addr     = "https://{{ sockaddr "GetPrivateIP" }}:8200"
cluster_addr = "https://{{ sockaddr "GetPrivateIP" }}:8201"
%{ else ~}
api_addr     = "http://{{ sockaddr "GetPrivateIP" }}:8200"
cluster_addr = "http://{{ sockaddr "GetPrivateIP" }}:8201"
%{ endif ~}
EOH
        destination = "local/vault.hcl"
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "vault"
        port     = "api"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          # HTTP router for ACME challenges and short name
          "traefik.http.routers.vault-http.rule=Host(`vault.${var.dns_postfix}`) || Host(`vault`) || Host(`ca.${var.dns_postfix}`) || Host(`ca`)",
          "traefik.http.routers.vault-http.entrypoints=web",
          # HTTPS router with TLS (Vault uses native OIDC, not forward auth)
          # Also accepts ca.<domain> for backwards compatibility with ACME clients
          "traefik.http.routers.vault.rule=Host(`vault.${var.dns_postfix}`) || Host(`vault`) || Host(`ca.${var.dns_postfix}`) || Host(`ca`)",
          "traefik.http.routers.vault.entrypoints=websecure",
          "traefik.http.routers.vault.tls=true",
          "traefik.http.services.vault.loadbalancer.server.port=8200",
          # Vault listens on HTTPS — tell Traefik to use HTTPS for the backend
          "traefik.http.services.vault.loadbalancer.server.scheme=https",
        ]

        check {
          type            = "http"
          protocol        = var.vault_tls_enabled ? "https" : "http"
          tls_skip_verify = var.vault_tls_enabled
          path            = "/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200"
          port            = "api"
          interval        = "10s"
          timeout          = "3s"
        }
      }
    }
  }
}
