job "vault" {
  datacenters = ["dc1"]
  # system job — one alloc per Nomad node, automatic placement.
  # Each instance is a Raft peer. No hostname constraint, no count.
  type = "system"

  group "vault" {
    network {
      mode = "host"
      port "api"     { static = 8200 }
      port "cluster" { static = 8201 }
    }

    # Belt-and-suspenders: refuse to start if the gluster brick isn't
    # mounted. Per-node Raft data lives under
    # /srv/gluster/nomad-data/vault/<hostname>, so we still need the
    # mount even though Raft does its own replication on top.
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

    # Each Vault instance lives at /srv/gluster/nomad-data/vault/<hostname>.
    # Pre-creating the directory is handled by null_resource.vault_directories
    # in terraform/main.tf — this prestart double-checks and creates if missing,
    # so the docker bind-mount doesn't fall back to a root-owned auto-created path.
    task "ensure-data-dir" {
      driver = "raw_exec"
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      config {
        command = "/bin/bash"
        args = [
          "-c",
          "sudo mkdir -p /srv/gluster/nomad-data/vault/$${node.unique.name} && sudo chmod 777 /srv/gluster/nomad-data/vault/$${node.unique.name}"
        ]
      }
      resources {
        cpu    = 10
        memory = 16
      }
    }

    task "vault" {
      driver = "docker"

      # Expose the Nomad node's hostname to the task as an env var so
      # consul-template can stamp it into vault.hcl as the raft node_id.
      # Runtime interpolation works in `meta` but NOT in `template.data`,
      # so this is the bridge.
      meta {
        hostname = "$${node.unique.name}"
      }

      env {
        SKIP_CHOWN    = "true"
        VAULT_ADDR    = ${vault_tls_enabled} ? "https://127.0.0.1:8200" : "http://127.0.0.1:8200"
        SSL_CERT_FILE = "/certs/root_ca.crt"
      }

      config {
        image        = "hashicorp/vault:${vault_version}"
        network_mode = "host"
        privileged   = true
        args         = ["server", "-config=/local/vault.hcl"]
        volumes = [
          # Per-node data dir — Raft requires each peer to have its own
          # storage path. Multiple peers writing to the same directory
          # would corrupt the WAL.
          "/srv/gluster/nomad-data/vault/$${node.unique.name}:/data/vault",
          "/srv/gluster/nomad-data/certs:/certs:ro",
          "/srv/gluster/nomad-data/vault-tls:/tls:ro",
        ]
      }

      template {
        data = <<EOH
ui = true
disable_mlock = true

storage "raft" {
  path    = "/data/vault"
  node_id = "{{ env "NOMAD_META_hostname" }}"

%{ for ip in nomad_node_ips ~}
  retry_join {
    leader_api_addr = "${vault_tls_enabled ? "https" : "http"}://${ip}:8200"
%{ if vault_tls_enabled ~}
    leader_ca_cert_file       = "/certs/root_ca.crt"
    leader_tls_servername     = "vault.${dns_postfix}"
%{ endif ~}
  }
%{ endfor ~}
}

cluster_name = "proxmox-lab-vault"

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "{{ sockaddr "GetPrivateIP" }}:8201"
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

        # standbyok=true → standby Vaults still report 200, so Traefik
        # keeps them in the pool. Reads are forwarded to the leader by
        # any standby; writes are HTTP-redirected.
        check {
          type            = "http"
          protocol        = ${vault_tls_enabled} ? "https" : "http"
          tls_skip_verify = ${vault_tls_enabled}
          path            = "/v1/sys/health?standbyok=true&perfstandbyok=true&uninitcode=200&sealedcode=200"
          port            = "api"
          interval        = "10s"
          timeout         = "3s"
        }
      }
    }
  }
}
