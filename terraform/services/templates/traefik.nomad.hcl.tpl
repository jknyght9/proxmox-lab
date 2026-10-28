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
%{ if acme_enabled ~}
        # acme.json lives on the host, not in the alloc dir, so a restart or
        # reschedule reuses the existing cert instead of re-issuing. This is a
        # system job, so each node keeps its own account and cert — see the
        # rate-limit note in bootstrap.yml.example before lowering renewal
        # intervals or redeploying in a loop.
        volumes = ["/var/lib/traefik-acme:/acme"]
%{ endif ~}
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
          # Since Traefik v3.0, respondingTimeouts.readTimeout defaults to 60s
          # and bounds the time to read a WHOLE request including its body, so
          # any upload over ~60s is killed (observed: `docker push` of large
          # container-registry layers to git.${dns_postfix} fails with 499 ~1
          # min in). Raise to 2h to allow multi-GB image layer pushes while
          # keeping some slowloris protection (0 would be unlimited).
          "--entrypoints.websecure.transport.respondingTimeouts.readTimeout=2h",
          "--entrypoints.traefik.address=:8081",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://127.0.0.1:4646",
          "--providers.nomad.exposedByDefault=false",
          "--providers.nomad.namespaces=default",
          "--providers.nomad.allowEmptyServices=true",
          "--providers.file.directory=/local/config",
          "--providers.file.watch=true",
          "--serversTransport.insecureSkipVerify=true",
%{ if acme_enabled ~}
          # Public ACME wildcard over DNS-01. Applied as the websecure
          # entrypoint's default, so every router inherits it and jobs keep
          # tagging only `tls=true` — no per-service certresolver tags, and no
          # per-service names in Certificate Transparency logs.
          "--certificatesresolvers.acme.acme.email=${acme_email}",
          "--certificatesresolvers.acme.acme.storage=/acme/acme.json",
          "--certificatesresolvers.acme.acme.caserver=${acme_ca_server}",
          "--certificatesresolvers.acme.acme.dnschallenge=true",
          "--certificatesresolvers.acme.acme.dnschallenge.provider=${acme_provider}",
          "--certificatesresolvers.acme.acme.dnschallenge.resolvers=${acme_dns_resolvers}",
          "--entrypoints.websecure.http.tls=true",
          "--entrypoints.websecure.http.tls.certresolver=acme",
          "--entrypoints.websecure.http.tls.domains[0].main=${dns_postfix}",
          "--entrypoints.websecure.http.tls.domains[0].sans=*.${dns_postfix}",
%{ endif ~}
        ]
      }

%{ if acme_enabled ~}
      # DNS-01 provider credentials, read from Vault at runtime via this
      # job's WIF role and exported as the env vars Traefik's provider code
      # expects (CF_DNS_API_TOKEN, AWS_*, AZURE_*, ...). Nothing secret is
      # rendered into the jobspec.
      template {
        data = <<EOH
{{ with secret "secret/data/infra/traefik/acme" }}
{{ range $k, $v := .Data.data }}{{ $k }}={{ $v }}
{{ end }}{{ end }}
EOH
        destination = "secrets/acme.env"
        env         = true
        perms       = "0600"
        change_mode = "restart"
      }
%{ else ~}
      # Wildcard cert (leaf + issuing CA). Lease tied to ttl below; Nomad
      # re-fetches when ~1/3 lease remains and RESTARTS the task to reload.
      # (SIGUSR1 did NOT reload Traefik's default cert — it served the stale
      # cert to expiry; change_mode=restart guarantees the renewed cert loads.)
      template {
        data = <<EOH
{{ with secret "pki_int/issue/acme-certs" "common_name=*.${dns_postfix}" "alt_names=${dns_postfix}" "ttl=2160h" }}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{ end }}
EOH
        destination   = "local/tls/cert.pem"
        perms         = "0644"
        change_mode   = "restart"
      }

      template {
        data = <<EOH
{{ with secret "pki_int/issue/acme-certs" "common_name=*.${dns_postfix}" "alt_names=${dns_postfix}" "ttl=2160h" }}
{{ .Data.private_key }}
{{ end }}
EOH
        destination   = "local/tls/key.pem"
        perms         = "0600"
        change_mode   = "restart"
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
%{ endif ~}

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
