# =============================================================================
# Traefik ACME credentials — provider secrets for DNS-01
#
# The credentials never reach the jobspec. They land in Vault here, and the
# Traefik job pulls them at runtime through its existing WIF role, rendering
# them straight into the task environment. Adding a provider (route53,
# azuredns, ...) needs no change to this file — only different keys in
# bootstrap.yml's traefik_acme.credentials map.
# =============================================================================

locals {
  # Let's Encrypt endpoints. An explicit traefik_acme_ca_server wins, so a
  # different CA (ZeroSSL, Buypass, an internal step-ca) just works.
  acme_ca_server = (
    var.traefik_acme_ca_server != "" ? var.traefik_acme_ca_server :
    var.traefik_acme_staging ? "https://acme-staging-v02.api.letsencrypt.org/directory" :
    "https://acme-v02.api.letsencrypt.org/directory"
  )

  # Only meaningful when the resolver is on AND credentials were supplied.
  acme_active = var.traefik_acme_enabled && length(var.traefik_acme_credentials) > 0
}

resource "vault_kv_secret_v2" "traefik_acme" {
  count = local.acme_active ? 1 : 0
  mount = vault_mount.secret.path
  name  = "infra/traefik/acme"

  data_json = jsonencode(var.traefik_acme_credentials)
}

# Fail early and loudly rather than letting Traefik boot with a resolver it
# cannot use — an ACME failure otherwise surfaces as a silent fallback to
# Traefik's self-signed default cert, which looks like a working deploy.
resource "null_resource" "traefik_acme_validation" {
  count = var.traefik_acme_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.traefik_acme_provider != ""
      error_message = "traefik_acme_enabled is set but traefik_acme.provider is empty. Set it to a Traefik DNS provider name (e.g. cloudflare)."
    }
    precondition {
      condition     = var.traefik_acme_email != ""
      error_message = "traefik_acme_enabled is set but traefik_acme.email is empty. Public ACME CAs require an account email."
    }
    precondition {
      condition     = length(var.traefik_acme_credentials) > 0
      error_message = "traefik_acme_enabled is set but traefik_acme.credentials is empty. Supply the provider's env vars, e.g. CF_DNS_API_TOKEN for cloudflare."
    }
  }
}
