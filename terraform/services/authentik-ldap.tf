# =============================================================================
# Authentik LDAP Outpost — credential passthrough for Kasm
#
# Architecture: Kasm → LDAP → Authentik LDAP Outpost → Authentik Core → AD
#
# Unlike SAML (token-only), LDAP passes actual credentials through to Kasm,
# enabling seamless SSH/RDP/VNC sessions without re-entering passwords.
#
# The outpost runs as a system job (all Nomad nodes) on ports 3389/6636
# to avoid conflict with Samba AD on standard LDAP ports 389/636.
# =============================================================================

# --- LDAP Provider ---

resource "authentik_provider_ldap" "kasm" {
  count       = var.deploy_authentik ? 1 : 0
  name        = "Kasm LDAP"
  base_dn     = "dc=${join(",dc=", split(".", var.dns_postfix))}"
  bind_flow   = data.authentik_flow.default_authentication[0].id
  unbind_flow = data.authentik_flow.default_invalidation[0].id
}

# --- Kasm Application (LDAP, available to all users) ---

resource "authentik_application" "kasm" {
  count              = var.deploy_authentik ? 1 : 0
  name               = "Kasm Workspaces"
  slug               = "kasm"
  protocol_provider  = authentik_provider_ldap.kasm[0].id
  meta_launch_url    = "https://kasm.${var.dns_postfix}"
  policy_engine_mode = "any"
  # No group binding — available to all users
}

# --- LDAP Outpost ---

resource "authentik_outpost" "ldap" {
  count              = var.deploy_authentik ? 1 : 0
  name               = "ldap-outpost"
  type               = "ldap"
  protocol_providers = [authentik_provider_ldap.kasm[0].id]
}

# --- Fetch Outpost Token + Deploy LDAP Outpost ---
# The authentik_outpost resource doesn't expose the auto-generated token.
# We fetch it via the Authentik API from a Nomad node, then deploy the
# outpost container with that token using nomad job run.

resource "null_resource" "authentik_ldap_deploy" {
  count      = var.deploy_authentik ? 1 : 0
  depends_on = [authentik_outpost.ldap, nomad_job.authentik]

  triggers = {
    outpost_id  = authentik_outpost.ldap[0].id
    dns_postfix = var.dns_postfix
  }

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
      echo '[+] Fetching LDAP outpost token from Authentik API...'

      # Get the outpost's token identifier
      TOKID=$(curl -sk -H "Authorization: Bearer ${var.authentik_api_token}" \
        "https://auth.${var.dns_postfix}/api/v3/outposts/instances/${authentik_outpost.ldap[0].id}/" \
        | jq -r '.token_identifier // empty')

      if [ -z "$TOKID" ]; then
        echo '[!] Could not find outpost token identifier'
        exit 1
      fi

      # Get the actual token key
      OUTPOST_TOKEN=$(curl -sk -H "Authorization: Bearer ${var.authentik_api_token}" \
        "https://auth.${var.dns_postfix}/api/v3/core/tokens/$TOKID/view_key/" \
        | jq -r '.key // empty')

      if [ -z "$OUTPOST_TOKEN" ]; then
        echo '[!] Could not retrieve outpost token key'
        exit 1
      fi

      echo "[+] Got outpost token: $${TOKID}"

      # Write and run the Nomad job
      cat > /tmp/authentik-ldap.nomad.hcl <<'JOBSPEC'
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
              image        = "ghcr.io/goauthentik/ldap:latest"
              network_mode = "host"
            }

            env {
              AUTHENTIK_HOST     = "https://auth.${var.dns_postfix}"
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
JOBSPEC

      # Inject the token as an environment variable (can't put it in the HCL directly due to escaping)
      # Use nomad job run with -var instead
      # Actually, write a modified version with the token
      sed -i "s|AUTHENTIK_INSECURE = \"true\"|AUTHENTIK_INSECURE = \"true\"\n              AUTHENTIK_TOKEN    = \"$OUTPOST_TOKEN\"|" /tmp/authentik-ldap.nomad.hcl

      echo '[+] Deploying LDAP outpost Nomad job...'
      nomad job run /tmp/authentik-ldap.nomad.hcl
      rm -f /tmp/authentik-ldap.nomad.hcl

      echo '[+] Authentik LDAP outpost deployed on all nodes (port 3389)'
      cat <<'KASMHELP'

============================================================
  Kasm LDAP Configuration (Manual — Kasm Admin UI)
============================================================

  Kasm Admin → Access Management → Authentication → LDAP
  → Add Configuration

  Name:                    Authentik LDAP
  URL:                     ldap://NOMAD_IP:3389
  Search Base:             DC_BASE_DN
  Search Filter:           (cn=%(user)s)
  Group Search Filter:     (objectClass=group)
  Group Member Attribute:  member
  Search Subtree:          enabled
  Auto Create App User:    enabled
  Service Account DN:      (leave empty — direct bind)
  Service Account Password: (leave empty)

  Replace NOMAD_IP with any Nomad node IP (system job on all):
KASMHELP
      echo "    ${local.nomad01_ip}:3389"
      echo "  Replace DC_BASE_DN with:"
      echo "    dc=${join(",dc=", split(".", var.dns_postfix))}"
      echo ""
      echo "============================================================"
      EOT
    ]
  }
}
