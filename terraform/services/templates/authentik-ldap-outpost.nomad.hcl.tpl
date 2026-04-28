job "authentik-ldap" {
  datacenters = ["dc1"]
  type        = "system"

  group "ldap" {
    network {
      mode = "host"
      port "ldap"  { static = 3389 }
      port "ldaps" { static = 6636 }
    }

    task "ldap-outpost" {
      driver = "docker"

      config {
        image        = "ghcr.io/goauthentik/ldap:2026.2.2"
        network_mode = "host"
      }

      env {
        AUTHENTIK_HOST     = "https://auth.${dns_postfix}"
        AUTHENTIK_TOKEN    = "${outpost_token}"
        AUTHENTIK_INSECURE = "true"
      }

      resources {
        cpu    = 100
        memory = 128
      }

      service {
        name     = "authentik-ldap"
        port     = "ldap"
        provider = "nomad"

        check {
          type     = "tcp"
          port     = "ldap"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
