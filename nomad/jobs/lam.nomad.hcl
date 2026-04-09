# LDAP Account Manager (LAM) - Web-based LDAP/AD user management
#
# Provides a web UI for managing Samba AD users, groups, and attributes.
# Protected by Authentik forward auth - only authenticated admins can access.

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

    network {
      port "http" {
        static = 8380
        to     = 80
      }
    }

    task "lam" {
      driver = "docker"

      config {
        image       = "ghcr.io/ldapaccountmanager/lam:stable"
        dns_servers = ["${DNS_SERVER}"]
        ports       = ["http"]

        volumes = [
          "/srv/gluster/nomad-data/lam/config:/etc/ldap-account-manager",
          "/srv/gluster/nomad-data/lam/session:/var/lib/ldap-account-manager/sess",
        ]
      }

      env {
        # LAM Configuration
        LDAP_DOMAIN          = "${AD_REALM_LOWER}"
        LDAP_BASE_DN         = "${BASE_DN}"
        LDAP_SERVER          = "ldaps://${NOMAD01_IP}"
        LDAP_USER            = "CN=Administrator,CN=Users,${BASE_DN}"
        LAM_LANG             = "en_US"
        LAM_PASSWORD         = "lam"  # Default config password, change after first login
        LAM_CONFIGURATION_DATABASE = "files"
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
          # HTTP router
          "traefik.http.routers.lam-http.rule=Host(`lam.${DNS_POSTFIX}`)",
          "traefik.http.routers.lam-http.entrypoints=web",
          # HTTPS router with Authentik forward auth
          "traefik.http.routers.lam.rule=Host(`lam.${DNS_POSTFIX}`)",
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
