# Samba AD Domain Controller Nomad Job
#
# Uses ghcr.io/jknyght9/samba-ad-dc Docker image which supports both:
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
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    # Vault integration - fetch secrets at runtime using Workload Identity
    vault {
      role        = "samba-dc"
      change_mode = "noop"  # Don't restart on secret change - AD is stateful
    }

    # Restart policy - handle transient failures during domain provisioning
    restart {
      attempts = 3
      interval = "5m"
      delay    = "30s"
      mode     = "delay"
    }

    network {
      mode = "host"
      # Samba DNS binds to port 53 by default in host network mode
      port "dns"      { static = 53 }
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
        image        = "ghcr.io/jknyght9/samba-ad-dc:latest"
        network_mode = "host"
        privileged   = true

        # Use local storage (not GlusterFS) - Samba AD requires POSIX ACL support
        # which GlusterFS FUSE doesn't provide. Each DC stores data locally.
        volumes = [
          "/opt/samba-dc01/samba:/var/lib/samba",
          "/opt/samba-dc01/krb5:/etc/krb5",
          "/opt/samba-dc01/smb.conf:/etc/samba/smb.conf",
        ]
      }

      template {
        data = <<EOH
{{ with secret "secret/data/samba-ad" }}
DOMAINPASS={{ .Data.data.admin_password }}
{{ end }}
{{ with secret "secret/data/config/cluster" }}
DOMAIN={{ .Data.data.ad_realm }}
DOMAINNAME={{ .Data.data.ad_domain }}
DNSFORWARDER={{ .Data.data.dns_forwarder }}
{{ end }}
{{ with secret "secret/data/config/nomad-nodes" }}
HOSTIP={{ .Data.data.nomad01_ip }}
{{ end }}
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
        port     = "ldaps"
        provider = "nomad"

        tags = [
          "dc=primary",
          "realm=${ad_realm}",
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
      attribute = "$${attr.unique.hostname}"
      value     = "nomad02"
    }

    # Vault integration - fetch secrets at runtime using Workload Identity
    vault {
      role        = "samba-dc"
      change_mode = "noop"  # Don't restart on secret change - AD is stateful
    }

    # Restart policy - handle transient failures during domain join
    restart {
      attempts = 3
      interval = "5m"
      delay    = "30s"
      mode     = "delay"
    }

    network {
      mode = "host"
      # Samba DNS binds to port 53 by default in host network mode
      port "dns"      { static = 53 }
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
        image        = "ghcr.io/jknyght9/samba-ad-dc:latest"
        network_mode = "host"
        privileged   = true

        # Use local storage (not GlusterFS) - Samba AD requires POSIX ACL support
        volumes = [
          "/opt/samba-dc02/samba:/var/lib/samba",
          "/opt/samba-dc02/krb5:/etc/krb5",
          "/opt/samba-dc02/smb.conf:/etc/samba/smb.conf",
        ]
      }

      template {
        data = <<EOH
{{ with secret "secret/data/samba-ad" }}
DOMAINPASS={{ .Data.data.admin_password }}
{{ end }}
{{ with secret "secret/data/config/cluster" }}
DOMAIN={{ .Data.data.ad_realm }}
DOMAINNAME={{ .Data.data.ad_domain }}
{{ end }}
{{ with secret "secret/data/config/nomad-nodes" }}
HOSTIP={{ .Data.data.nomad02_ip }}
DNSFORWARDER={{ .Data.data.nomad01_ip }}
DCIP={{ .Data.data.nomad01_ip }}
{{ end }}
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
        port     = "ldaps"
        provider = "nomad"

        tags = [
          "dc=replica",
          "realm=${ad_realm}",
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
