#!/usr/bin/env bash
# Rendered by terraform templatefile() and executed on nomad01 (the only host
# allowed to reach the UniFi controller :443). Reconciles the lab's local DNS
# A-records into UniFi's static-dns store, SCOPED so it only ever deletes
# records it previously created (tracked in $STATE), never app/hand-added ones.
#
# terraform vars (single $): ${unifi_address} ${unifi_site} ${desired_json}
# bash vars are written with $$ so templatefile emits a literal $.
set -euo pipefail

BASE_URL="https://${unifi_address}/proxy/network/v2/api/site/${unifi_site}/static-dns"
DESIRED_JSON='${desired_json}'

: "$${UNIFI_API_KEY:?UNIFI_API_KEY env var required}"
STATE_DIR=/opt/unifi-dns-tf
STATE="$$STATE_DIR/managed.json"
mkdir -p "$$STATE_DIR"

TMP="$$(mktemp -d)"
trap 'rm -rf "$$TMP"' EXIT

# Serialize against every other UniFi DNS writer (coordinated with lab-templates'
# modules/dns-unifi). The UDM API has no transaction semantics, so concurrent
# reconciles can race on a stale GET — one writer deleting a record another just
# created. All writers take the same host lock on nomad01; -w 30 so a wedged
# writer fails rather than queueing forever. Lock is held (fd 9) until exit.
exec 9>/var/lock/unifi-dns-tf.lock
flock -w 30 9 || { echo "[!] could not acquire /var/lock/unifi-dns-tf.lock within 30s" >&2; exit 1; }

curl_api() {
  # $1=method  $2=path-suffix  $3=json-body(optional)
  local method="$$1" path="$$2" data="$${3:-}" code
  if [ -n "$$data" ]; then
    code="$$(curl -sk -m 15 -o "$$TMP/resp" -w '%%{http_code}' -X "$$method" \
      -H "X-API-KEY: $$UNIFI_API_KEY" -H 'Content-Type: application/json' -H 'Accept: application/json' \
      "$$BASE_URL$$path" -d "$$data")"
  else
    code="$$(curl -sk -m 15 -o "$$TMP/resp" -w '%%{http_code}' -X "$$method" \
      -H "X-API-KEY: $$UNIFI_API_KEY" -H 'Accept: application/json' "$$BASE_URL$$path")"
  fi
  if [ "$$code" -ge 400 ]; then
    echo "[!] UniFi API $$method $$BASE_URL$$path -> HTTP $$code" >&2
    cat "$$TMP/resp" >&2 2>/dev/null || true; echo >&2
    return 1
  fi
  cat "$$TMP/resp"
}

echo "[+] Fetching existing UniFi static-dns records..."
curl_api GET "" > "$$TMP/existing.json"

echo "$$DESIRED_JSON" > "$$TMP/desired.json"
mapfile -t DESIRED < <(jq -r '.[] | "\(.key)|\(.value)"' "$$TMP/desired.json" | sort -u)

# Index existing A-records: "key|value" -> _id
declare -A EXISTING_ID
while IFS='|' read -r k v id; do
  [ -n "$$k" ] && EXISTING_ID["$$k|$$v"]="$$id"
done < <(jq -r '.[] | select(.record_type=="A") | "\(.key)|\(.value)|\(._id)"' "$$TMP/existing.json")

# Create desired records that don't already exist
created=0
for kv in "$${DESIRED[@]:-}"; do
  [ -z "$$kv" ] && continue
  if [ -n "$${EXISTING_ID[$$kv]:-}" ]; then continue; fi
  key="$${kv%%|*}"; value="$${kv##*|}"
  body="$$(jq -nc --arg k "$$key" --arg v "$$value" '{key:$$k, record_type:"A", value:$$v, enabled:true}')"
  curl_api POST "" "$$body" >/dev/null
  echo "  + created $$key -> $$value"
  created=$$((created + 1))
done

# Scoped prune: delete only records WE previously created (in $STATE) that are
# no longer desired. Records added via the app/UI are absent from $STATE and
# are left untouched.
deleted=0
declare -A DESIRED_SET
for kv in "$${DESIRED[@]:-}"; do [ -n "$$kv" ] && DESIRED_SET["$$kv"]=1; done
if [ -f "$$STATE" ]; then
  mapfile -t PRIOR < <(jq -r '.[]' "$$STATE" 2>/dev/null | sort -u)
  for kv in "$${PRIOR[@]:-}"; do
    [ -z "$$kv" ] && continue
    if [ -z "$${DESIRED_SET[$$kv]:-}" ]; then
      id="$${EXISTING_ID[$$kv]:-}"
      if [ -n "$$id" ]; then
        curl_api DELETE "/$$id" >/dev/null
        echo "  - deleted $$kv"
        deleted=$$((deleted + 1))
      fi
    fi
  done
fi

# Persist the new managed set (= desired)
printf '%s\n' "$${DESIRED[@]:-}" | jq -R . | jq -s 'map(select(length > 0))' > "$$STATE"

echo "[+] UniFi DNS reconcile complete: $$created created, $$deleted deleted, $${#DESIRED[@]} desired."
