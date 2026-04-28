# =============================================================================
# Docs Build — copies MkDocs source to nomad01 and builds there
#
# The docs/ directory and mkdocs.yml are mounted into the Terraform container
# at /docs and /mkdocs.yml. This resource copies them to nomad01, builds the
# static site using Docker, and deploys to GlusterFS.
# =============================================================================

resource "null_resource" "docs_build" {
  depends_on = [null_resource.service_directories]

  triggers = {
    dns_postfix = var.dns_postfix
    docs_hash   = sha256(join("", [for f in fileset("/docs", "**/*.md") : filesha256("/docs/${f}")]))
  }

  # Copy docs to nomad01
  provisioner "file" {
    source      = "/docs"
    destination = "/tmp/docs-build"

    connection {
      type        = "ssh"
      host        = local.nomad01_ip
      user        = "labadmin"
      private_key = file(var.ssh_admin_private_key_file)
    }
  }

  # Copy mkdocs.yml to nomad01
  provisioner "file" {
    source      = "/mkdocs.yml"
    destination = "/tmp/docs-build-mkdocs.yml"

    connection {
      type        = "ssh"
      host        = local.nomad01_ip
      user        = "labadmin"
      private_key = file(var.ssh_admin_private_key_file)
    }
  }

  # Build on nomad01 and deploy to GlusterFS
  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e
      echo '[+] Building documentation...'

      # Update site_name and site_url
      sed -i \
        -e 's/^site_name:.*/site_name: ${var.dns_postfix}/' \
        -e 's|^site_url:.*|site_url: https://docs.${var.dns_postfix}|' \
        /tmp/docs-build-mkdocs.yml

      # Build MkDocs site using Docker on nomad01
      mkdir -p /tmp/docs-build-site
      docker run --rm \
        -v /tmp/docs-build:/docs/docs:ro \
        -v /tmp/docs-build-mkdocs.yml:/docs/mkdocs.yml:ro \
        -v /tmp/docs-build-site:/docs/site \
        squidfunk/mkdocs-material build --clean 2>&1 | tail -3

      # Fix permissions (Docker creates files as root)
      sudo chmod -R 777 /tmp/docs-build-site

      # Replace domain placeholders
      find /tmp/docs-build-site -name '*.html' -exec sed -i \
        -e 's/&lt;dns-suffix&gt;/${var.dns_postfix}/g' \
        -e 's/<dns-suffix>/${var.dns_postfix}/g' \
        -e 's/&lt;nomad01-ip&gt;/${local.nomad01_ip}/g' \
        -e 's/<nomad01-ip>/${local.nomad01_ip}/g' {} +

      # Deploy to GlusterFS
      sudo mkdir -p /srv/gluster/nomad-data/docs/site
      sudo cp -r /tmp/docs-build-site/* /srv/gluster/nomad-data/docs/site/
      sudo chmod -R 755 /srv/gluster/nomad-data/docs/site

      # Cleanup
      rm -rf /tmp/docs-build /tmp/docs-build-mkdocs.yml /tmp/docs-build-site

      echo '[+] Documentation deployed'
      EOT
    ]
  }
}
