#!/usr/bin/env bash
# =============================================================================
# Repeatable install of the versitygw TrueNAS catalog app (community train) via
# the TrueNAS API. Bootstrap: creates the app + an ixVolume ZFS dataset for its
# bucket storage (native xattrs + ZFS snapshots; visible in the TrueNAS Apps UI).
# Deliberately NOT a Terraform resource — versitygw is the state backend and must
# not live in the state it holds.
#
# Env:
#   TRUENAS_ADDR     TrueNAS host/IP (e.g. 10.1.50.20)
#   TRUENAS_API_KEY  TrueNAS API key
#   VAULT_ADDR, VAULT_TOKEN   read root S3 keys from secret/versitygw
#   API_PORT   S3 API port (default 7070)    APP_NAME (default versitygw)
#   VGW_VERSION chart version (default 1.1.15)
# Idempotent: if the app already exists it skips create.
# =============================================================================
set -euo pipefail
: "${TRUENAS_ADDR:?set TRUENAS_ADDR}" "${TRUENAS_API_KEY:?set TRUENAS_API_KEY}"
: "${VAULT_ADDR:?set VAULT_ADDR}" "${VAULT_TOKEN:?set VAULT_TOKEN}"
API_PORT="${API_PORT:-7070}"; APP="${APP_NAME:-versitygw}"; VER="${VGW_VERSION:-1.1.15}"
API="https://$TRUENAS_ADDR/api/v2.0"

tn()  { curl -sk -m30 -H "Authorization: Bearer $TRUENAS_API_KEY" -H 'Content-Type: application/json' "$@"; }
vget() { curl -sk -m10 -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/$1"; }

SEC="$(vget secret/data/versitygw)"
AK="$(echo "$SEC" | jq -r '.data.data.access_key_id // empty')"
SK="$(echo "$SEC" | jq -r '.data.data.secret_access_key // empty')"
[ -n "$AK" ] && [ -n "$SK" ] || { echo "[!] root keys missing in Vault secret/versitygw" >&2; exit 1; }

if tn "$API/app/id/$APP" 2>/dev/null | jq -e --arg a "$APP" '.name? == $a' >/dev/null 2>&1; then
  echo "[=] app '$APP' already exists on $TRUENAS_ADDR — nothing to do."
  exit 0
fi

VALUES="$(jq -nc --arg ak "$AK" --arg sk "$SK" --argjson port "$API_PORT" '{
  TZ:"Etc/UTC",
  versity:{root_user_access_key:$ak, root_user_secret_access_key:$sk,
           additional_envs:[], additional_global_flags:[], additional_posix_flags:[]},
  run_as:{user:568, group:568},
  network:{
    webui_port:{bind_mode:"published", port_number:30355, host_ips:[]},
    api_port:{bind_mode:"published", port_number:$port, host_ips:[]},
    admin_port:{bind_mode:"published", port_number:30158, host_ips:[]},
    networks:[], host_network:false
  },
  storage:{
    buckets:{type:"ix_volume",
             ix_volume_config:{acl_enable:false, dataset_name:"buckets"}},
    additional_storage:[]
  },
  labels:[],
  resources:{limits:{cpus:2, memory:4096}}
}')"

BODY="$(jq -nc --arg app "$APP" --arg ver "$VER" --argjson vals "$VALUES" \
  '{app_name:$app, catalog_app:"versitygw", train:"community", version:$ver, values:$vals}')"

echo "[*] creating '$APP' (versitygw $VER, S3 API :$API_PORT, ixVolume 'buckets')..."
JID="$(tn -X POST "$API/app" -d "$BODY")"
if ! echo "$JID" | grep -qE '^[0-9]+$'; then
  echo "[!] app.create did not return a job id: $JID" >&2; exit 1
fi
echo "[*] app.create job $JID — waiting..."
for i in $(seq 1 120); do
  J="$(tn "$API/core/get_jobs?id=$JID")"
  ST="$(echo "$J" | jq -r '.[0].state // empty')"
  case "$ST" in
    SUCCESS) echo "[+] app '$APP' created."; break;;
    FAILED)  echo "[!] job failed: $(echo "$J" | jq -r '.[0].error')" >&2; exit 1;;
  esac
  [ "$i" = "120" ] && { echo "[!] timed out waiting for app.create" >&2; exit 1; }
  sleep 5
done

echo "[+] versitygw installed on $TRUENAS_ADDR — S3 API http://$TRUENAS_ADDR:$API_PORT"
echo "    next: create buckets + run tools/s3-lock-probe.sh (the state-lock gate)."
