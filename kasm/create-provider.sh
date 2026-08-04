#!/bin/sh
# create-provider.sh <config-json> <startup-ps1>
#
# Creates OR updates a Kasm VM Provider Config from a JSON body file, merging
# in Proxmox connection fields from Vault (via lib.sh) and inlining the
# startup script from a separate .ps1 file. Idempotent: if a config with the
# same `config_name` already exists, updates it; otherwise creates.
#
# Example:
#   . ./lib.sh; kasm_init
#   ./create-provider.sh configs/win11-standalone-pve01-provider.json \
#                       configs/startup-standalone.ps1

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib.sh"

if [ $# -ne 2 ]; then
    echo "usage: $0 <config-json> <startup-ps1>" >&2
    exit 2
fi
CONFIG_JSON=$1
STARTUP_PS1=$2

[ -f "$CONFIG_JSON" ] || { echo "[ERROR] missing $CONFIG_JSON" >&2; exit 1; }
[ -f "$STARTUP_PS1" ] || { echo "[ERROR] missing $STARTUP_PS1" >&2; exit 1; }

# Ensure creds are loaded (idempotent -- kasm_init sets globals)
[ -n "${KASM_API_KEY:-}" ] || kasm_init

CONFIG_NAME=$(jq -r '.config_name' "$CONFIG_JSON")
[ -n "$CONFIG_NAME" ] && [ "$CONFIG_NAME" != "null" ] || {
    echo "[ERROR] $CONFIG_JSON missing .config_name" >&2; exit 1
}

# Build the target_vm_provider_config body: base JSON + Proxmox connection +
# inlined startup script (with $env: substitutions preserved by --rawfile).
TARGET=$(jq -c \
    --arg host  "$PROXMOX_HOST" \
    --arg user  "$PROXMOX_USERNAME" \
    --arg tname "$PROXMOX_TOKEN_NAME" \
    --arg tval  "$PROXMOX_TOKEN_VALUE" \
    --rawfile startup "$STARTUP_PS1" \
    '. + {
        host: $host,
        username: $user,
        token_name: $tname,
        token_value: $tval,
        startup_script: $startup
    }' "$CONFIG_JSON")

# Look up existing config by name
EXISTING_ID=$(kasm_api api/admin/get_vm_provider_configs '{}' | \
    jq -r --arg n "$CONFIG_NAME" \
    '.vm_provider_configs[]? | select(.config_name == $n) | .config_id' | head -1)

if [ -n "$EXISTING_ID" ]; then
    echo "[+] updating $CONFIG_NAME (config_id=$EXISTING_ID)"
    # Attach the existing ID so Kasm knows which one to update.
    BODY=$(echo "$TARGET" | jq --arg id "$EXISTING_ID" '. + {config_id: $id}')
    RESP=$(kasm_api api/admin/update_vm_provider_config "{\"target_vm_provider_config\": $BODY}")
else
    echo "[+] creating $CONFIG_NAME"
    RESP=$(kasm_api api/admin/create_vm_provider_config "{\"target_vm_provider_config\": $TARGET}")
fi

if echo "$RESP" | jq -e '.error_message' >/dev/null 2>&1; then
    echo "[ERROR] $(echo "$RESP" | jq -c .)" >&2
    exit 1
fi

echo "[OK] $CONFIG_NAME -> config_id=$(echo "$RESP" | jq -r '.vm_provider_config.config_id // .config_id // .vm_provider_config_id // "?"')"
