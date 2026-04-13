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
