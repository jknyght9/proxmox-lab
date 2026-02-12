job "vault" {
  datacenters = ["dc1"]
  type        = "service"

  group "vault" {
    count = 1

    network {
      mode = "host"
      port "api"     { static = 8200 }
      port "cluster" { static = 8201 }
    }

    volume "vault-data" {
      type   = "host"
      source = "gluster-data"
    }

    task "vault" {
      driver = "docker"

      volume_mount {
        volume      = "vault-data"
        destination = "/vault"
      }

      config {
        image        = "hashicorp/vault:1.15"
        network_mode = "host"
        cap_add      = ["IPC_LOCK"]
        args         = ["server", "-config=/vault/config/vault.hcl"]
        volumes = [
          "local/vault.hcl:/vault/config/vault.hcl:ro",
        ]
      }

      template {
        data = <<EOH
ui = true
disable_mlock = false

storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr = "http://{{ env "NOMAD_IP_api" }}:8200"
cluster_addr = "http://{{ env "NOMAD_IP_cluster" }}:8201"
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
          "traefik.http.routers.vault.rule=Host(`vault.${DNS_POSTFIX}`)",
          "traefik.http.routers.vault.entrypoints=websecure",
          "traefik.http.routers.vault.tls=true",
          "traefik.http.routers.vault.tls.certresolver=step-ca",
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
