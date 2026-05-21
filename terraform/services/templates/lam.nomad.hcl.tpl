# LDAP Account Manager (LAM) - Web-based LDAP/AD user management
#
# Provides a web UI for managing Samba AD users, groups, and attributes.
# Protected by Authentik forward auth - only authenticated admins can access.
# AD config read from Vault KV at secret/config/cluster and secret/config/nomad-nodes.

job "lam" {
  datacenters = ["dc1"]
  type        = "service"

  group "lam" {
    count = 1

    # Pin to nomad01 for consistent access
    constraint {
      attribute = "$${attr.unique.hostname}"
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

      # Override 9.6.RC1's USER=www-data so the bootstrap script can sed
      # /usr/share/ldap-account-manager/lib/treeview.inc. apache2 drops
      # back to www-data via its own config after binding port 80.
      user = "root"

      config {
        image   = "ghcr.io/ldapaccountmanager/lam:9.6.RC1"
        ports   = ["http"]
        command = "/bin/bash"
        args    = ["/local/lam-bootstrap.sh"]

        volumes = [
          "/srv/gluster/nomad-data/lam/config:/etc/ldap-account-manager",
          "/srv/gluster/nomad-data/lam/profile:/var/lib/ldap-account-manager/config",
          "/srv/gluster/nomad-data/lam/session:/var/lib/ldap-account-manager/sess",
        ]
      }

      # Bootstrap: patches LAM <=9.6.RC1 treeview bug + forces followReferrals=true.
      # See lib/treeview.inc::getNodeIcon — array_map() crashes when Samba AD
      # returns LDAP referrals (Configuration/DomainDnsZones/ForestDnsZones
      # partitions) as entries with no objectClass attribute. followReferrals=true
      # makes LAM chase the refs and get real entries with objectClass set; the
      # PHP patch keeps the page rendering even if a refless entry slips through.
      template {
        data = <<EOH
#!/bin/bash
set -e
sed -i "s|array_map(strtolower(...), \$attributes\['objectclass'\])|array_map(strtolower(...), \$attributes['objectclass'] ?? [])|" /usr/share/ldap-account-manager/lib/treeview.inc
sed -i 's|"followReferrals": "false"|"followReferrals": "true"|' /var/lib/ldap-account-manager/config/unix.sample.conf 2>/dev/null || true
[ -f /var/lib/ldap-account-manager/config/lam.conf ] && sed -i 's|"followReferrals": "false"|"followReferrals": "true"|' /var/lib/ldap-account-manager/config/lam.conf
exec /usr/local/bin/start.sh
EOH
        destination = "local/lam-bootstrap.sh"
        perms       = "0755"
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
          "traefik.http.routers.lam-http.rule=Host(`lam.${dns_postfix}`)",
          "traefik.http.routers.lam-http.entrypoints=web",
          "traefik.http.routers.lam.rule=Host(`lam.${dns_postfix}`)",
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
