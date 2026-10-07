#!/usr/bin/env bash
# =============================================================================
# Pulse agent install — rendered by terraform templatefile(), executed (sudo)
# on each Nomad VM. Installs/refreshes the Pulse agent (host + Docker metrics)
# with a per-node token.
#
# Token: reused from Vault (secret/pulse-agents/<node>) if present, else minted
# once via the Pulse API (POST /api/security/tokens -> .token) and cached in
# Vault so re-runs don't mint duplicates. Each host gets its own token.
#
# templatefile vars interpolated by terraform: vault_address, vault_token, node,
#   pulse_api   (Pulse API base for token mint/login, e.g. http://nomad01:7655),
#   pulse_url   (installer fetch + agent --url target),
#   agent_flags (capability flags for the installer, e.g. "--enable-docker" for
#     Docker hosts, "--enable-host" for bare PVE hosts),
#   token_scopes (JSON array of Pulse token scopes for this agent).
# Shell $vars / $(...) stay single; the curl write-out format is doubled (%%) so
# templatefile emits a literal percent-brace.
# =============================================================================
set -e

VAULT_ADDR="${vault_address}"
VAULT_TOKEN="${vault_token}"
NODE="${node}"
PULSE_API="${pulse_api}"
PULSE_URL="${pulse_url}"
JAR="$(mktemp)"
RESP="$(mktemp)"
trap 'rm -f "$JAR" "$RESP"' EXIT

vault_get() { curl -sk -m5 -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/$1"; }

# --- token: reuse from Vault, else mint via Pulse API --------------------------
TOK="$(vault_get secret/data/pulse-agents/$NODE | jq -r '.data.data.token // empty')"
if [ -n "$TOK" ]; then
  echo "[+] token: reused from Vault (secret/pulse-agents/$NODE)"
else
  echo "[+] token: minting via Pulse API for $NODE..."
  ADMIN_PW="$(vault_get secret/data/pulse | jq -r '.data.data.admin_password // empty')"
  [ -n "$ADMIN_PW" ] || { echo '[!] secret/pulse admin_password missing in Vault'; exit 1; }

  LOGIN_CODE="$(curl -s -m10 -o /dev/null -w '%%{http_code}' -c "$JAR" \
    -H 'Content-Type: application/json' -X POST "$PULSE_API/api/login" \
    -d "$(jq -nc --arg p "$ADMIN_PW" '{username:"admin",password:$p}')")"
  [ "$LOGIN_CODE" = "200" ] || { echo "[!] Pulse login failed (HTTP $LOGIN_CODE)"; exit 1; }
  CSRF="$(awk '/pulse_csrf/{print $NF}' "$JAR" | tail -1)"
  [ -n "$CSRF" ] || { echo '[!] no pulse_csrf cookie after login'; exit 1; }

  MINT_CODE="$(curl -s -m10 -o "$RESP" -w '%%{http_code}' -b "$JAR" -H "X-CSRF-Token: $CSRF" \
    -H 'Content-Type: application/json' -X POST "$PULSE_API/api/security/tokens" \
    -d "$(jq -nc --arg n "pulse-agent-$NODE" --argjson s '${token_scopes}' '{name:$n,scopes:$s}')")"
  [ "$MINT_CODE" -ge 400 ] && { echo "[!] token mint HTTP $MINT_CODE"; cat "$RESP"; exit 1; }
  TOK="$(jq -r '.token // empty' "$RESP")"
  [ -n "$TOK" ] || { echo '[!] mint response had no .token field'; cat "$RESP"; exit 1; }

  STORE_CODE="$(curl -sk -m5 -o /dev/null -w '%%{http_code}' -H "X-Vault-Token: $VAULT_TOKEN" \
    -H 'Content-Type: application/json' -X POST "$VAULT_ADDR/v1/secret/data/pulse-agents/$NODE" \
    -d "$(jq -nc --arg t "$TOK" --arg n "pulse-agent-$NODE" '{data:{token:$t,name:$n}}')")"
  [ "$STORE_CODE" -ge 400 ] && { echo "[!] Vault store HTTP $STORE_CODE"; exit 1; }
  echo "[+] token: minted + cached in Vault (secret/pulse-agents/$NODE)"
fi

# --- install / refresh the agent -----------------------------------------------
INSTALLER="$(mktemp)"
echo "[+] fetching installer from $PULSE_URL/install.sh ..."
if ! curl -fsSL -m30 "$PULSE_URL/install.sh" -o "$INSTALLER"; then
  echo "[!] https installer fetch failed — falling back to $PULSE_API/install.sh"
  curl -fsSL -m30 "$PULSE_API/install.sh" -o "$INSTALLER" \
    || { echo '[!] installer download failed'; exit 1; }
fi

echo "[+] running agent installer on $NODE ..."
bash "$INSTALLER" --url "$PULSE_URL" --token "$TOK" ${agent_flags} --non-interactive
rm -f "$INSTALLER"
echo "[+] pulse agent install/refresh complete on $NODE"
