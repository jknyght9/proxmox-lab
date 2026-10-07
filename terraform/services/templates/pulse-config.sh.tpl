#!/usr/bin/env bash
# =============================================================================
# Pulse config reconcile — rendered by terraform templatefile(), executed on
# nomad01 (Pulse listens on 127.0.0.1:7655, host network — no TLS hop).
#
# Idempotently configures, via Pulse's REST API:
#   1. the Authentik OIDC SSO provider (with caBundle = the mounted root CA), and
#   2. the Proxmox cluster (one member; Pulse auto-discovers the rest).
# Create-or-update: GET + match, PUT if present else POST (POST always mints a
# new UUID, so a blind POST would duplicate on every apply).
#
# templatefile vars interpolated by terraform: vault_address, vault_token,
#   pve_host, dns_postfix, allowed_groups_json (JSON array of SSO groups allowed
#   to log in; [] = no restriction), group_role_map_json (JSON object mapping SSO
#   group -> Pulse role; {} = no role mapping). Shell brace-expansions are
#   written $${...}; plain $var and $(...) stay single.
# =============================================================================
set -e

PULSE="http://127.0.0.1:7655"
VAULT_ADDR="${vault_address}"
VAULT_TOKEN="${vault_token}"
PVE_HOST="${pve_host}"
JAR="$(mktemp)"
RESP="$(mktemp)"
trap 'rm -f "$JAR" "$RESP"' EXIT

echo '[+] Waiting for Pulse API (127.0.0.1:7655)...'
for i in $(seq 1 60); do
  curl -sf -m3 "$PULSE/api/health" >/dev/null 2>&1 && break
  [ "$i" = "60" ] && { echo '[!] Pulse API not healthy after 120s'; exit 1; }
  sleep 2
done

# --- secrets from Vault --------------------------------------------------------
vault_get() { curl -sk -m5 -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/$1"; }
PULSE_SECRET="$(vault_get secret/data/pulse)"
OIDC_SECRET="$(vault_get secret/data/pulse-oidc)"
ADMIN_PW="$(echo "$PULSE_SECRET" | jq -r '.data.data.admin_password // empty')"
PVE_TID="$(echo "$PULSE_SECRET" | jq -r '.data.data.pve_token_id // empty')"
PVE_TOK_FULL="$(echo "$PULSE_SECRET" | jq -r '.data.data.pve_token // empty')"
PVE_BARE="$${PVE_TOK_FULL##*=}"
OIDC_ISSUER="$(echo "$OIDC_SECRET" | jq -r '.data.data.oidc_endpoint // empty')"
OIDC_CLIENT_SECRET="$(echo "$OIDC_SECRET" | jq -r '.data.data.oidc_client_secret // empty')"

[ -n "$ADMIN_PW" ] || { echo '[!] secret/pulse admin_password not found in Vault'; exit 1; }

# --- login (session cookie + CSRF double-submit) -------------------------------
echo '[+] Logging into Pulse...'
LOGIN_CODE="$(curl -s -m10 -o /dev/null -w '%%{http_code}' -c "$JAR" \
  -H 'Content-Type: application/json' -X POST "$PULSE/api/login" \
  -d "$(jq -nc --arg u admin --arg p "$ADMIN_PW" '{username:$u,password:$p}')")"
[ "$LOGIN_CODE" = "200" ] || { echo "[!] Pulse login failed (HTTP $LOGIN_CODE)"; exit 1; }
CSRF="$(awk '/pulse_csrf/{print $NF}' "$JAR" | tail -1)"
[ -n "$CSRF" ] || { echo '[!] No pulse_csrf cookie after login'; exit 1; }

# api METHOD PATH BODY -> writes response to $RESP, sets $LAST_CODE
api() {
  LAST_CODE="$(curl -s -m15 -o "$RESP" -w '%%{http_code}' \
    -b "$JAR" -H "X-CSRF-Token: $CSRF" -H 'Content-Type: application/json' \
    -X "$1" "$PULSE$2" -d "$3")"
}

# --- SSO provider (match by oidcClientId == "pulse") ---------------------------
if [ -n "$OIDC_ISSUER" ]; then
  echo '[+] Reconciling Authentik OIDC SSO provider...'
  # Pulse v6.4.5 requires the OIDC parameters NESTED under an "oidc" object; a
  # flat payload returns 400 "OIDC configuration is required". Pulse echoes them
  # back as flat oidc* fields on read, so the GET-match below still keys on
  # oidcClientId=="pulse".
  #
  # Access control + RBAC (SSOProvider struct, verified against Pulse source):
  #   allowedGroups / groupsClaim / groupRoleMappings are TOP-LEVEL fields;
  #   scopes is nested under oidc. Pulse's default scopes are openid/profile/
  #   email (NO groups), so without requesting "groups" the IdP never sends the
  #   groups claim and no role mapping or group restriction can work — hence
  #   scopes always includes "groups". allowedGroups/groupRoleMappings come from
  #   the site's group lists (empty => no restriction / no elevation).
  SSO_BODY="$(jq -nc --arg iss "$OIDC_ISSUER" --arg cs "$OIDC_CLIENT_SECRET" \
    --argjson ag '${allowed_groups_json}' --argjson grm '${group_role_map_json}' \
    '{name:"Authentik",type:"oidc",enabled:true,
      allowedGroups:$ag,groupsClaim:"groups",groupRoleMappings:$grm,
      oidc:{issuerUrl:$iss,clientId:"pulse",clientSecret:$cs,
            caBundle:"/local/certs/root_ca.crt",
            scopes:["openid","profile","email","groups"]}}')"
  SSO_ID="$(curl -s -m10 -b "$JAR" "$PULSE/api/security/sso/providers" \
    | jq -r '[.providers[]? | select(.oidcClientId=="pulse")][0].id // empty')"
  if [ -n "$SSO_ID" ]; then
    api PUT "/api/security/sso/providers/$SSO_ID" "$SSO_BODY"
    [ "$LAST_CODE" -ge 400 ] && { echo "[!] SSO update HTTP $LAST_CODE"; cat "$RESP"; exit 1; }
    echo "    SSO provider updated ($SSO_ID)"
  else
    api POST "/api/security/sso/providers" "$SSO_BODY"
    [ "$LAST_CODE" -ge 400 ] && { echo "[!] SSO create HTTP $LAST_CODE"; cat "$RESP"; exit 1; }
    echo "    SSO provider created"
  fi
else
  echo '[!] secret/pulse-oidc not populated yet — skipping SSO (run authentik_apps first)'
fi

# --- Proxmox cluster (match by host) -------------------------------------------
if [ -n "$PVE_HOST" ]; then
  echo "[+] Reconciling Proxmox cluster ($PVE_HOST)..."
  # Pulse v6.4.5 requires a "name" on node create (else 400 "Name is required").
  # Derive a stable, site-agnostic label from the DNS suffix (e.g. iotvf.lab ->
  # iotvf-pve) rather than hardcoding a site value.
  PVE_NAME="$(echo "${dns_postfix}" | cut -d. -f1)-pve"
  PVE_BODY="$(jq -nc --arg h "$PVE_HOST" --arg n "$PVE_NAME" --arg tn "$PVE_TID" --arg tv "$PVE_BARE" \
    '{type:"pve",name:$n,host:$h,tokenName:$tn,tokenValue:$tv,verifySSL:false,monitorVMs:true,monitorContainers:true,monitorStorage:true,monitorBackups:true,enabled:true}')"
  api POST "/api/config/nodes/test-connection" "$PVE_BODY" || true
  echo "    test-connection: $(jq -r '.message // ("nodeCount=" + (.nodeCount|tostring)) // "n/a"' "$RESP" 2>/dev/null || echo n/a)"
  PVE_ID="$(curl -s -m10 -b "$JAR" "$PULSE/api/config/nodes" \
    | jq -r --arg h "$PVE_HOST" '[.[]? | select(.type=="pve" and .host==$h)][0].id // empty')"
  if [ -n "$PVE_ID" ]; then
    api PUT "/api/config/nodes/$PVE_ID" "$PVE_BODY"
    [ "$LAST_CODE" -ge 400 ] && { echo "[!] PVE update HTTP $LAST_CODE"; cat "$RESP"; exit 1; }
    echo "    PVE cluster updated ($PVE_ID)"
  else
    api POST "/api/config/nodes" "$PVE_BODY"
    [ "$LAST_CODE" -ge 400 ] && { echo "[!] PVE create HTTP $LAST_CODE"; cat "$RESP"; exit 1; }
    echo "    PVE cluster created"
  fi
else
  echo '[i] pulse_pve_host empty — skipping PVE auto-add'
fi

echo '[+] Pulse config reconcile complete.'
