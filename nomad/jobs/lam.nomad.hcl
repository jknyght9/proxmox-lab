# LDAP Account Manager (LAM) - Web-based LDAP/AD user management
#
# Provides a web UI for managing Samba AD users, groups, and attributes.
# Protected by Authentik forward auth - only authenticated admins can access.
# AD config read from Vault KV at secret/config/cluster and secret/config/nomad-nodes.

variable "dns_postfix" {
  type        = string
  description = "Domain suffix for service DNS"
}

job "lam" {
  datacenters = ["dc1"]
  type        = "service"

  group "lam" {
    count = 1

    # Pin to nomad01 for consistent access
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }

    # Vault integration — read AD config from KV
    vault {
      role        = "lam"
      change_mode = "restart"
    }

    network {
      port "http" {
        static = 8380
        to     = 80
      }
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

    task "lam" {
      driver = "docker"

      config {
        image       = "ghcr.io/ldapaccountmanager/lam:stable"
        ports       = ["http"]

        volumes = [
          "/srv/gluster/nomad-data/lam/config:/etc/ldap-account-manager",
          "/srv/gluster/nomad-data/lam/session:/var/lib/ldap-account-manager/sess",
        ]
      }

      # AD config injected from Vault KV via template
      template {
        data = <<EOH
{{ with secret "secret/data/config/cluster" }}
LDAP_DOMAIN={{ .Data.data.ad_realm_lower }}
LDAP_BASE_DN={{ .Data.data.base_dn }}
LDAP_USER=CN=Administrator,CN=Users,{{ .Data.data.base_dn }}
{{ end }}
{{ with secret "secret/data/config/nomad-nodes" }}
LDAP_SERVER=ldaps://{{ .Data.data.nomad01_ip }}
{{ end }}
{{ with secret "secret/data/config/cluster" }}
DNS_SERVER={{ .Data.data.dns_server }}
{{ end }}
LAM_LANG=en_US
LAM_PASSWORD=lam
LAM_CONFIGURATION_DATABASE=files
LDAPTLS_REQCERT=allow
EOH
        destination = "secrets/lam.env"
        env         = true
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "lam"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.lam-http.rule=Host(`lam.${var.dns_postfix}`)",
          "traefik.http.routers.lam-http.entrypoints=web",
          "traefik.http.routers.lam.rule=Host(`lam.${var.dns_postfix}`)",
          "traefik.http.routers.lam.entrypoints=websecure",
          "traefik.http.routers.lam.tls=true",
          "traefik.http.routers.lam.middlewares=authentik@file",
          "traefik.http.services.lam.loadbalancer.server.port=8380",
        ]

        check {
          type     = "http"
          path     = "/"
          port     = "http"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
