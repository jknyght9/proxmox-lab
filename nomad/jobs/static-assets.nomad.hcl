job "static-assets" {
  datacenters = ["dc1"]
  type        = "service"

  group "nginx" {
    count = 1

    constraint {
      attribute = "${attr.unique.hostname}"
      value     = "nomad01"
    }

    network {
      mode = "host"
      port "http" { static = 8088 }
    }

    task "nginx" {
      driver = "docker"

      config {
        image        = "nginx:alpine"
        network_mode = "host"
        volumes = [
          "/srv/gluster/nomad-data/static-assets:/usr/share/nginx/html:ro",
          "local/nginx.conf:/etc/nginx/conf.d/default.conf:ro",
        ]
      }

      template {
        data = <<EOH
server {
    listen 8088;
    server_name _;

    root /usr/share/nginx/html;

    location / {
        autoindex off;
        try_files $uri $uri/ =404;

        # CORS headers for fonts and assets
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "public, max-age=31536000";
    }

    # Health check
    location /health {
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
EOH
        destination = "local/nginx.conf"
      }

      resources {
        cpu    = 50
        memory = 32
      }

      service {
        name     = "static-assets"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          # Serve over HTTP only (no TLS) to avoid CA trust issues for branding assets
          "traefik.http.routers.static-assets.rule=Host(`assets.${DNS_POSTFIX}`)",
          "traefik.http.routers.static-assets.entrypoints=web",
          "traefik.http.services.static-assets.loadbalancer.server.port=8088",
        ]

        check {
          type     = "http"
          path     = "/health"
          port     = "http"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
