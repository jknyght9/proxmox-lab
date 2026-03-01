# NOTE: This is a REFERENCE TEMPLATE. The actual job file is generated dynamically
# by lib/deploy/nomadJob/deploySambaAD.sh with variable substitution.
#
# Uses nowsci/samba-domain Docker image which supports both:
# - JOIN=false: Provision new AD domain (DC01)
# - JOIN=true: Join existing domain as replica (DC02)

job "samba-dc" {
  datacenters = ["dc1"]
  type        = "service"

  # ===========================================================================
  # Primary Domain Controller (DC01) - Provisions new AD domain
  # ===========================================================================
  group "dc01" {
    count = 1

    # Pin to nomad01 for consistent DNS and service discovery
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }

    # Vault integration - fetch secrets at runtime using Workload Identity
    vault {
      role        = "samba-dc"
      change_mode = "noop"  # Don't restart on secret change - AD is stateful
    }

    network {
      mode = "host"
      # Using port 5353 for internal DNS to avoid conflict with Pi-hole on 53
      port "dns"      { static = 5353 }
      port "kerberos" { static = 88 }
      port "ldap"     { static = 389 }
      port "ldaps"    { static = 636 }
      port "smb"      { static = 445 }
      port "gc"       { static = 3268 }  # Global Catalog
      port "gcs"      { static = 3269 }  # Global Catalog SSL
    }

    task "samba-dc" {
      driver = "docker"

      # Graceful shutdown for AD replication consistency
      kill_timeout = "120s"

      config {
        image        = "nowsci/samba-domain:latest"
        network_mode = "host"
        privileged   = true

        volumes = [
          "/srv/gluster/nomad-data/samba-dc01/samba:/var/lib/samba",
          "/srv/gluster/nomad-data/samba-dc01/krb5:/etc/krb5",
        ]
      }

      template {
        data = <<EOH
{{ with secret "secret/data/samba-ad" }}
DOMAINPASS={{ .Data.data.admin_password }}
{{ end }}
DOMAIN=${AD_REALM}
HOSTIP=${NOMAD01_IP}
DNSFORWARDER=${DNS_FORWARDER}
JOIN=false
INSECURELDAP=true
NOCOMPLEXITY=true
EOH
        destination = "secrets/samba.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "samba-dc01"
        port     = "ldap"
        provider = "nomad"

        tags = [
          "dc=primary",
          "realm=${AD_REALM}",
        ]

        check {
          type     = "tcp"
          port     = "ldap"
          interval = "30s"
          timeout  = "5s"
        }
      }

      service {
        name     = "samba-dc01-kerberos"
        port     = "kerberos"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "kerberos"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }

  # ===========================================================================
  # Replica Domain Controller (DC02) - Joins existing domain
  # ===========================================================================
  group "dc02" {
    count = 1

    # Pin to nomad02 for HA - different node than DC01
    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad02"
    }

    # Vault integration - fetch secrets at runtime using Workload Identity
    vault {
      role        = "samba-dc"
      change_mode = "noop"  # Don't restart on secret change - AD is stateful
    }

    network {
      mode = "host"
      # Using port 5354 for internal DNS to avoid conflict
      port "dns"      { static = 5354 }
      port "kerberos" { static = 88 }
      port "ldap"     { static = 389 }
      port "ldaps"    { static = 636 }
      port "smb"      { static = 445 }
      port "gc"       { static = 3268 }
      port "gcs"      { static = 3269 }
    }

    task "samba-dc" {
      driver = "docker"

      # Graceful shutdown for AD replication consistency
      kill_timeout = "120s"

      config {
        image        = "nowsci/samba-domain:latest"
        network_mode = "host"
        privileged   = true

        volumes = [
          "/srv/gluster/nomad-data/samba-dc02/samba:/var/lib/samba",
          "/srv/gluster/nomad-data/samba-dc02/krb5:/etc/krb5",
        ]
      }

      template {
        data = <<EOH
{{ with secret "secret/data/samba-ad" }}
DOMAINPASS={{ .Data.data.admin_password }}
{{ end }}
DOMAIN=${AD_REALM}
HOSTIP=${NOMAD02_IP}
DNSFORWARDER=${NOMAD01_IP}
JOIN=true
JOINSITE=Default-First-Site-Name
INSECURELDAP=true
NOCOMPLEXITY=true
EOH
        destination = "secrets/samba.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 1024
      }

      service {
        name     = "samba-dc02"
        port     = "ldap"
        provider = "nomad"

        tags = [
          "dc=replica",
          "realm=${AD_REALM}",
        ]

        check {
          type     = "tcp"
          port     = "ldap"
          interval = "30s"
          timeout  = "5s"
        }
      }

      service {
        name     = "samba-dc02-kerberos"
        port     = "kerberos"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "kerberos"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
