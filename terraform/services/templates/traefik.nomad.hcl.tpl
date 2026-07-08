job "traefik" {
  datacenters = ["dc1"]
  type        = "system"

  group "traefik" {
    network {
      mode = "host"
      port "http" { static = 80 }
      port "https" { static = 443 }
      port "dashboard" { static = 8081 }
    }

    # Vault integration — each Traefik alloc mints its own wildcard cert
    # from Vault PKI via the templates below. No shared filesystem for
    # cert files. change_signal=USR1 makes Traefik reload in-place when
    # the cert is renewed (Nomad re-renders the templates near lease
    # expiry, signals USR1, Traefik picks up the new cert without
    # restarting the container).
    vault {
      role          = "traefik"
      change_mode   = "signal"
      change_signal = "SIGUSR1"
    }

    task "traefik" {
      driver = "docker"

      config {
        image        = "traefik:v3.6.14"
        network_mode = "host"
        dns_servers  = ["${dns_server}"]
        args = [
          "--log.level=DEBUG",
          "--api=true",
          "--api.dashboard=true",
          "--api.insecure=true",
          "--ping=true",
          "--ping.entryPoint=traefik",
          "--entrypoints.web.address=:80",
          "--entrypoints.web.http.redirections.entryPoint.to=websecure",
          "--entrypoints.web.http.redirections.entryPoint.scheme=https",
          "--entrypoints.web.http.redirections.entryPoint.permanent=true",
          "--entrypoints.websecure.address=:443",
          "--entrypoints.traefik.address=:8081",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://127.0.0.1:4646",
          "--providers.nomad.exposedByDefault=false",
          "--providers.nomad.namespaces=default",
          "--providers.nomad.allowEmptyServices=true",
          "--providers.file.directory=/local/config",
          "--providers.file.watch=true",
          "--serversTransport.insecureSkipVerify=true",
        ]
      }

      # Wildcard cert (leaf + issuing CA). Lease tied to ttl below;
      # Nomad re-fetches when ~1/3 lease remains and signals USR1.
      template {
        data = <<EOH
{{ with secret "pki_int/issue/acme-certs" "common_name=*.${dns_postfix}" "alt_names=${dns_postfix}" "ttl=2160h" }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{ end }}
EOH
        destination   = "local/tls/cert.pem"
        perms         = "0644"
        change_mode   = "signal"
        change_signal = "SIGUSR1"
      }

      template {
        data = <<EOH
{{ with secret "pki_int/issue/acme-certs" "common_name=*.${dns_postfix}" "alt_names=${dns_postfix}" "ttl=2160h" }}
{{ .Data.private_key }}
{{ end }}
EOH
        destination   = "local/tls/key.pem"
        perms         = "0600"
        change_mode   = "signal"
        change_signal = "SIGUSR1"
      }

      # File-provider config — points Traefik at the templated cert files.
      # Static content, doesn't change at runtime; no signal on change.
      template {
        data = <<EOH
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /local/tls/cert.pem
        keyFile: /local/tls/key.pem
EOH
        destination = "local/config/tls.yml"
        perms       = "0644"
        change_mode = "noop"
      }

      # Authentik forward-auth middleware + routers for Nomad UI, Pi-hole UI,
      # and the Traefik dashboard. Previously written to gluster by
      # null_resource.traefik_config (vm-nomad/main.tf); now rendered into
      # the alloc-local file-provider dir so Traefik picks it up the same
      # way it picks up tls.yml. Content mirrors vm-nomad/templates/
      # traefik-authentik.yml.tpl — keep them in sync until Phase 3 deletes
      # the vm-nomad copy.
      template {
        data = <<EOH
http:
  middlewares:
    authentik:
      forwardAuth:
        address: http://${nomad01_ip}:9000/outpost.goauthentik.io/auth/traefik
        trustForwardHeader: true
        authResponseHeaders:
          - X-authentik-username
          - X-authentik-groups
          - X-authentik-email
          - X-authentik-name
          - X-authentik-uid
          - X-authentik-jwt
          - X-authentik-meta-app
          - X-authentik-meta-provider

  routers:
    nomad:
      rule: "Host(`nomad.${dns_postfix}`)"
      entryPoints:
        - websecure
      service: nomad
      middlewares:
        - authentik
      tls: {}

    pihole:
      rule: "Host(`pihole.${dns_postfix}`)"
      entryPoints:
        - websecure
      service: pihole
      middlewares:
        - authentik
      tls: {}

    traefik-dashboard:
      rule: "Host(`traefik.${dns_postfix}`)"
      entryPoints:
        - websecure
      service: traefik-dashboard
      middlewares:
        - authentik
      tls: {}

  services:
    nomad:
      loadBalancer:
        servers:
%{ for ip in nomad_ips ~}
          - url: "http://${ip}:4646"
%{ endfor ~}

    pihole:
      loadBalancer:
        servers:
          - url: "http://${dns01_ip}:80"

    traefik-dashboard:
      loadBalancer:
        servers:
          - url: "http://${nomad01_ip}:8081"
EOH
        destination = "local/config/authentik.yml"
        perms       = "0644"
        change_mode = "noop"
      }

      resources {
        cpu    = 200
        memory = 256
      }

      service {
        name     = "traefik"
        port     = "dashboard"
        provider = "nomad"

        check {
          type     = "http"
          path     = "/ping"
          port     = "dashboard"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
