# =============================================================================
# Authentik Applications & Providers
#
# Configures SSO protection for deployed services:
# - Vault: OIDC provider (native auth integration)
# - Pi-hole, Traefik, Nomad, Uptime Kuma, LAM: Proxy providers (forward auth)
#
# Access control:
# - All users: Kasm (SAML, configured separately)
# - Admins only: Pi-hole, Traefik, Vault, Nomad, Uptime Kuma, LAM
# =============================================================================

# --- Admin Group (for access policies) ---

# Use Domain Admins group if AD is synced, otherwise create an Authentik-native admin group
resource "authentik_group" "admins" {
  count        = var.configure_authentik ? 1 : 0
  name         = "Infrastructure Admins"
  is_superuser = false
}

# --- Authorization Flow (reuse default) ---

data "authentik_flow" "default_authorization" {
  count = var.configure_authentik ? 1 : 0
  slug  = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_authentication" {
  count = var.configure_authentik ? 1 : 0
  slug  = "default-authentication-flow"
}

data "authentik_flow" "default_invalidation" {
  count = var.configure_authentik ? 1 : 0
  slug  = "default-invalidation-flow"
}

# --- Proxy Providers (forward auth via Traefik) ---

resource "authentik_provider_proxy" "pihole" {
  count              = var.configure_authentik ? 1 : 0
  name               = "Pi-hole"
  authorization_flow = data.authentik_flow.default_authorization[0].id
  invalidation_flow  = data.authentik_flow.default_invalidation[0].id
  mode               = "forward_single"
  external_host      = "https://pihole.${var.dns_postfix}"
}

resource "authentik_provider_proxy" "traefik" {
  count              = var.configure_authentik ? 1 : 0
  name               = "Traefik"
  authorization_flow = data.authentik_flow.default_authorization[0].id
  invalidation_flow  = data.authentik_flow.default_invalidation[0].id
  mode               = "forward_single"
  external_host      = "https://traefik.${var.dns_postfix}"
}

resource "authentik_provider_proxy" "nomad" {
  count              = var.configure_authentik ? 1 : 0
  name               = "Nomad"
  authorization_flow = data.authentik_flow.default_authorization[0].id
  invalidation_flow  = data.authentik_flow.default_invalidation[0].id
  mode               = "forward_single"
  external_host      = "https://nomad.${var.dns_postfix}"
}

resource "authentik_provider_proxy" "uptime_kuma" {
  count              = var.deploy_authentik && var.deploy_uptime_kuma ? 1 : 0
  name               = "Uptime Kuma"
  authorization_flow = data.authentik_flow.default_authorization[0].id
  invalidation_flow  = data.authentik_flow.default_invalidation[0].id
  mode               = "forward_single"
  external_host      = "https://status.${var.dns_postfix}"
}

resource "authentik_provider_proxy" "lam" {
  count              = var.deploy_authentik && var.deploy_lam ? 1 : 0
  name               = "LDAP Account Manager"
  authorization_flow = data.authentik_flow.default_authorization[0].id
  invalidation_flow  = data.authentik_flow.default_invalidation[0].id
  mode               = "forward_single"
  external_host      = "https://lam.${var.dns_postfix}"
}

# --- Vault OIDC Provider ---

resource "authentik_provider_oauth2" "vault" {
  count               = var.configure_authentik ? 1 : 0
  name                = "Vault"
  authorization_flow  = data.authentik_flow.default_authorization[0].id
  invalidation_flow   = data.authentik_flow.default_invalidation[0].id
  client_id           = "vault"
  client_type         = "confidential"
  allowed_redirect_uris = [
    {matching_mode = "strict", url = "https://vault.${var.dns_postfix}/ui/vault/auth/oidc/oidc/callback"},
    {matching_mode = "strict", url = "https://vault.${var.dns_postfix}/v1/auth/oidc/oidc/callback"},
  ]
  signing_key         = data.authentik_certificate_key_pair.default[0].id
}

data "authentik_certificate_key_pair" "default" {
  count = var.configure_authentik ? 1 : 0
  name  = "authentik Self-signed Certificate"
}

# --- Applications ---

resource "authentik_application" "pihole" {
  count              = var.configure_authentik ? 1 : 0
  name               = "Pi-hole"
  slug               = "pihole"
  protocol_provider  = authentik_provider_proxy.pihole[0].id
  group              = "Admin"
  meta_launch_url    = "https://pihole.${var.dns_postfix}/admin/"
  meta_icon          = "https://pi-hole.github.io/graphics/Vortex/Vortex_Logo_Only.svg"
  policy_engine_mode = "any"
}

resource "authentik_application" "traefik" {
  count              = var.configure_authentik ? 1 : 0
  name               = "Traefik"
  slug               = "traefik"
  protocol_provider  = authentik_provider_proxy.traefik[0].id
  group              = "Admin"
  meta_launch_url    = "https://traefik.${var.dns_postfix}/"
  policy_engine_mode = "any"
}

resource "authentik_application" "nomad" {
  count              = var.configure_authentik ? 1 : 0
  name               = "Nomad"
  slug               = "nomad"
  protocol_provider  = authentik_provider_proxy.nomad[0].id
  group              = "Admin"
  meta_launch_url    = "https://nomad.${var.dns_postfix}/ui/"
  policy_engine_mode = "any"
}

resource "authentik_application" "vault" {
  count              = var.configure_authentik ? 1 : 0
  name               = "Vault"
  slug               = "vault"
  protocol_provider  = authentik_provider_oauth2.vault[0].id
  group              = "Admin"
  meta_launch_url    = "https://vault.${var.dns_postfix}/ui/"
  policy_engine_mode = "any"
}

resource "authentik_application" "uptime_kuma" {
  count              = var.deploy_authentik && var.deploy_uptime_kuma ? 1 : 0
  name               = "Uptime Kuma"
  slug               = "uptime-kuma"
  protocol_provider  = authentik_provider_proxy.uptime_kuma[0].id
  group              = "Admin"
  meta_launch_url    = "https://status.${var.dns_postfix}/"
  policy_engine_mode = "any"
}

resource "authentik_application" "lam" {
  count              = var.deploy_authentik && var.deploy_lam ? 1 : 0
  name               = "LDAP Account Manager"
  slug               = "lam"
  protocol_provider  = authentik_provider_proxy.lam[0].id
  group              = "Admin"
  meta_launch_url    = "https://lam.${var.dns_postfix}/"
  policy_engine_mode = "any"
}

# --- Access Policies (restrict admin apps to admin group) ---

resource "authentik_policy_binding" "pihole_admin" {
  count  = var.configure_authentik ? 1 : 0
  target = authentik_application.pihole[0].uuid
  group  = authentik_group.admins[0].id
  order  = 0
}

resource "authentik_policy_binding" "traefik_admin" {
  count  = var.configure_authentik ? 1 : 0
  target = authentik_application.traefik[0].uuid
  group  = authentik_group.admins[0].id
  order  = 0
}

resource "authentik_policy_binding" "nomad_admin" {
  count  = var.configure_authentik ? 1 : 0
  target = authentik_application.nomad[0].uuid
  group  = authentik_group.admins[0].id
  order  = 0
}

resource "authentik_policy_binding" "vault_admin" {
  count  = var.configure_authentik ? 1 : 0
  target = authentik_application.vault[0].uuid
  group  = authentik_group.admins[0].id
  order  = 0
}

resource "authentik_policy_binding" "uptime_kuma_admin" {
  count  = var.deploy_authentik && var.deploy_uptime_kuma ? 1 : 0
  target = authentik_application.uptime_kuma[0].uuid
  group  = authentik_group.admins[0].id
  order  = 0
}

resource "authentik_policy_binding" "lam_admin" {
  count  = var.deploy_authentik && var.deploy_lam ? 1 : 0
  target = authentik_application.lam[0].uuid
  group  = authentik_group.admins[0].id
  order  = 0
}
