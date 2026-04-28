job "docs" {
  datacenters = ["dc1"]
  type        = "service"

  group "docs" {
    count = 1

    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    network {
      mode = "host"
      port "http" { static = 8090 }
    }

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

    task "nginx" {
      driver = "docker"

      config {
        image        = "nginx:stable-alpine"
        network_mode = "host"
        volumes = [
          "/srv/gluster/nomad-data/docs/site:/usr/share/nginx/html:ro",
          "local/nginx.conf:/etc/nginx/conf.d/default.conf:ro",
        ]
      }

      template {
        data = <<NGINX
server {
    listen 8090;
    server_name docs.${dns_postfix} docs;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $${uri} $${uri}/ /index.html;
    }
}
NGINX
        destination = "local/nginx.conf"
      }

      resources {
        cpu    = 50
        memory = 64
      }

      service {
        name     = "docs"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.docs.rule=Host(`docs.${dns_postfix}`) || Host(`docs`)",
          "traefik.http.routers.docs.entrypoints=websecure",
          "traefik.http.routers.docs.tls=true",
          "traefik.http.services.docs.loadbalancer.server.port=8090",
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
