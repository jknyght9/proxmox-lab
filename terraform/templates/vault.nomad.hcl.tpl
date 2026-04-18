job "vault" {
  datacenters = ["dc1"]
  type        = "service"

  group "vault" {
    count = 1

    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    network {
      mode = "host"
      port "api"     { static = 8200 }
      port "cluster" { static = 8201 }
    }

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
        VAULT_ADDR = ${vault_tls_enabled} ? "https://127.0.0.1:8200" : "http://127.0.0.1:8200"
        SSL_CERT_FILE = "/certs/root_ca.crt"
      }

      config {
        image        = "hashicorp/vault:${vault_version}"
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
${vault_tls_enabled ? <<-TLS
  tls_cert_file   = "/tls/cert.pem"
  tls_key_file    = "/tls/key.pem"
  tls_min_version = "tls12"
TLS
: "  tls_disable = true"}
}

${vault_tls_enabled ? <<-TLS
api_addr     = "https://{{ sockaddr "GetPrivateIP" }}:8200"
cluster_addr = "https://{{ sockaddr "GetPrivateIP" }}:8201"
TLS
: <<-NOTLS
api_addr     = "http://{{ sockaddr "GetPrivateIP" }}:8200"
cluster_addr = "http://{{ sockaddr "GetPrivateIP" }}:8201"
NOTLS
}
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
          "traefik.http.routers.vault-http.rule=Host(`vault.${dns_postfix}`) || Host(`vault`) || Host(`ca.${dns_postfix}`) || Host(`ca`)",
          "traefik.http.routers.vault-http.entrypoints=web",
          "traefik.http.routers.vault.rule=Host(`vault.${dns_postfix}`) || Host(`vault`) || Host(`ca.${dns_postfix}`) || Host(`ca`)",
          "traefik.http.routers.vault.entrypoints=websecure",
          "traefik.http.routers.vault.tls=true",
          "traefik.http.services.vault.loadbalancer.server.port=8200",
          "traefik.http.services.vault.loadbalancer.server.scheme=https",
        ]

        check {
          type            = "http"
          protocol        = ${vault_tls_enabled} ? "https" : "http"
          tls_skip_verify = ${vault_tls_enabled}
          path            = "/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200"
          port            = "api"
          interval        = "10s"
          timeout         = "3s"
        }
      }
    }
  }
}
