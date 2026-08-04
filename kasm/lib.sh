#!/bin/sh
# Shared helpers for kasm/*.sh. Source, don't execute.
#
# POSIX sh -- the terraform container's alpine base ships busybox ash. No bash.
#
# Usage from a driver script:
#   . "$(dirname "$0")/lib.sh"
#   kasm_init            # ensures curl/jq present, fetches Kasm + Proxmox creds
#   r=$(kasm_api api/admin/get_vm_provider_configs '{}')
#   echo "$r" | jq ...

VAULT_ADDR="${VAULT_ADDR:-https://vault.iotvf.lab:8200}"
VAULT_KASM_PATH="${VAULT_KASM_PATH:-secret/data/kasm}"
VAULT_PROXMOX_PATH="${VAULT_PROXMOX_PATH:-secret/data/proxmox/api}"
KASM_HOST="${KASM_HOST:-kasm.iotvf.lab}"

# ---------- ensure curl + jq exist (alpine base is minimal) ----------
_ensure_pkg() {
    _p=$1
    command -v "$_p" >/dev/null 2>&1 && return 0
    apk add --no-cache "$_p" >/dev/null 2>&1 || sleep 3
    command -v "$_p" >/dev/null 2>&1
}

kasm_init() {
    _ensure_pkg curl || { echo "[ERROR] curl unavailable" >&2; return 1; }
    _ensure_pkg jq   || { echo "[ERROR] jq unavailable" >&2; return 1; }

    if [ -z "${VAULT_TOKEN:-}" ]; then
        echo "[ERROR] VAULT_TOKEN not set -- source .env or export it before running" >&2
        return 1
    fi

    # Fetch Kasm admin API creds
    _resp=$(curl -sk --max-time 15 "$VAULT_ADDR/v1/$VAULT_KASM_PATH" -H "X-Vault-Token: $VAULT_TOKEN")
    KASM_API_KEY=$(echo "$_resp" | jq -r '.data.data.api_key // empty')
    KASM_API_KEY_SECRET=$(echo "$_resp" | jq -r '.data.data.api_key_secret // empty')
    if [ -z "$KASM_API_KEY" ] || [ -z "$KASM_API_KEY_SECRET" ]; then
        echo "[ERROR] Kasm creds missing at $VAULT_KASM_PATH (expected api_key + api_key_secret)" >&2
        return 1
    fi

    # Fetch Proxmox token components for provider configs
    _resp=$(curl -sk --max-time 15 "$VAULT_ADDR/v1/$VAULT_PROXMOX_PATH" -H "X-Vault-Token: $VAULT_TOKEN")
    _tok=$(echo "$_resp" | jq -r '.data.data.kasm_api_token // empty')
    if [ -z "$_tok" ]; then
        echo "[ERROR] kasm_api_token missing at $VAULT_PROXMOX_PATH" >&2
        return 1
    fi
    PROXMOX_ENDPOINT=$(echo "$_resp" | jq -r '.data.data.endpoint // empty')
    PROXMOX_HOST=$(echo "$PROXMOX_ENDPOINT" | sed -E 's|^https?://||')
    PROXMOX_USERNAME=$(echo "$_tok" | cut -d'!' -f1)
    PROXMOX_TOKEN_NAME=$(echo "$_tok" | cut -d'!' -f2 | cut -d= -f1)
    PROXMOX_TOKEN_VALUE=$(echo "$_tok" | cut -d= -f2-)

    export KASM_API_KEY KASM_API_KEY_SECRET
    export PROXMOX_HOST PROXMOX_USERNAME PROXMOX_TOKEN_NAME PROXMOX_TOKEN_VALUE
}

# kasm_api <path-without-leading-slash> [json-body-fields-object]
# Pre-injects api_key + api_key_secret; merges caller's object at top level.
kasm_api() {
    _path=$1
    _body_fields=${2:-'{}'}
    _body=$(echo "$_body_fields" | jq -c \
        --arg k "$KASM_API_KEY" --arg s "$KASM_API_KEY_SECRET" \
        '. + {api_key: $k, api_key_secret: $s}')
    curl -sk --max-time 30 -X POST "https://$KASM_HOST/$_path" \
        -H 'Content-Type: application/json' \
        -d "$_body"
}
