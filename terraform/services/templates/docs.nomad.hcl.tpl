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

    # MkDocs build artifacts live on the cluster_state NAS via CSI/NFS.
    # See nas-shares.tf for the dataset/share and csi-volumes.tf for the
    # registration. The previous gluster mount kept the site under a
    # docs/site subdir; the NFS share now holds the site contents directly
    # at root (so volume_mount destination can be /usr/share/nginx/html).
    volume "data" {
      type            = "csi"
      source          = "docs-data"
      access_mode     = "multi-node-reader-only"
      attachment_mode = "file-system"
      read_only       = true
    }

    task "nginx" {
      driver = "docker"

      config {
        image        = "nginx:stable-alpine"
        network_mode = "host"
        volumes = [
          "local/nginx.conf:/etc/nginx/conf.d/default.conf:ro",
        ]
      }

      volume_mount {
        volume      = "data"
        destination = "/usr/share/nginx/html"
        read_only   = true
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
