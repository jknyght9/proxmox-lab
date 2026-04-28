# =============================================================================
# Authentik LDAP Outpost — DISABLED
#
# The Authentik 2026.2 LDAP outpost has a bug where the authorization flow
# cannot establish a session context for the user info API call, causing
# "failed to get user info: 403 Forbidden" after successful bind.
#
# Kasm is configured for direct Samba AD LDAP (port 389) instead.
# This file is a placeholder until the upstream issue is resolved.
#
# Tracking: https://github.com/goauthentik/authentik/issues/XXXXX
# Feature branch: feature/authentik-ldap-outpost
# =============================================================================
