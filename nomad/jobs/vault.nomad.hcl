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

    task "vault" {
      driver = "docker"

      env {
        SKIP_CHOWN = "true"
        VAULT_ADDR = "http://127.0.0.1:8200"
        # Trust internal CA for OIDC discovery
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
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr = "http://{{ sockaddr "GetPrivateIP" }}:8200"
cluster_addr = "http://{{ sockaddr "GetPrivateIP" }}:8201"
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
          "traefik.http.routers.vault-http.rule=Host(`vault.${DNS_POSTFIX}`) || Host(`vault`)",
          "traefik.http.routers.vault-http.entrypoints=web",
          # HTTPS router with TLS and Authentik forward auth
          "traefik.http.routers.vault.rule=Host(`vault.${DNS_POSTFIX}`) || Host(`vault`)",
          "traefik.http.routers.vault.entrypoints=websecure",
          "traefik.http.routers.vault.tls=true",
          "traefik.http.routers.vault.tls.certresolver=step-ca",
          "traefik.http.routers.vault.middlewares=authentik@file",
          "traefik.http.services.vault.loadbalancer.server.port=8200",
        ]

        check {
          type     = "http"
          path     = "/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200"
          port     = "api"
          interval = "10s"
          timeout  = "3s"
        }
      }
    }
  }
}
