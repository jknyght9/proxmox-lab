job "netbox-sync" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    cron             = "${sync_cron}"
    prohibit_overlap = true
    time_zone        = "${sync_timezone}"
  }

  group "sync" {
    count = 1

    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    vault {
      role        = "netbox-sync"
      change_mode = "restart"
    }

    task "sync" {
      driver = "docker"

      config {
        image        = "alpine:3.20"
        network_mode = "host"
        command      = "/bin/sh"
        args         = ["/local/sync.sh"]
      }

      template {
        data = <<SCRIPT
#!/bin/sh
set -eu

# Install dependencies — alpine doesn't ship with curl/jq
apk add --no-cache curl jq >/dev/null 2>&1

# Pull credentials from Vault (Workload Identity)
{{ with secret "secret/data/netbox" }}
NETBOX_TOKEN="{{ .Data.data.api_token }}"
{{ end }}

{{ with secret "secret/data/unifi" }}
UNIFI_ADDR="{{ .Data.data.address }}"
UNIFI_KEY="{{ .Data.data.api_key }}"
UNIFI_SITE="{{ .Data.data.site }}"
{{ end }}

{{ with secret "secret/data/config/cluster" }}
DNS_POSTFIX="{{ .Data.data.dns_postfix }}"
{{ end }}

# Netbox API runs on nomad01 host port (we're on the host network)
API="http://127.0.0.1:8080/api"
AUTH="Authorization: Token $NETBOX_TOKEN"
UNIFI="https://$UNIFI_ADDR"

if [ -z "$UNIFI_ADDR" ] || [ -z "$UNIFI_KEY" ]; then
  echo "[!] UniFi credentials missing in Vault — nothing to sync"
  exit 0
fi

echo "[+] Netbox inventory sync — UniFi controller $UNIFI_ADDR"

# Helper: get-or-create a Netbox resource
nb_create() {
  endpoint="$1"; match_field="$2"; match_value="$3"; payload="$4"
  id=$(curl -sk -H "$AUTH" "$API/$endpoint/" \
    | jq -r --arg v "$match_value" --arg f "$match_field" \
      '[.results[] | select(.[$f] == $v)][0].id // empty')
  if [ -n "$id" ]; then echo "$id"; return; fi
  id=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
    -X POST "$API/$endpoint/" -d "$payload" | jq -r '.id // empty')
  echo "$id"
}

# --- Devices ---
DEVICES=$(curl -sk -H "X-API-Key: $UNIFI_KEY" \
  "$UNIFI/proxy/network/api/s/$UNIFI_SITE/stat/device" 2>/dev/null)

if [ -z "$DEVICES" ] || ! echo "$DEVICES" | jq -e '.meta.rc == "ok"' >/dev/null 2>&1; then
  echo "[!] UniFi API query failed — check address/key"
  exit 1
fi

DEVICE_COUNT=$(echo "$DEVICES" | jq '.data | length')
echo "[+] Found $DEVICE_COUNT UniFi devices"

SITE_ID=$(curl -sk -H "$AUTH" "$API/dcim/sites/?slug=${site_slug}" | jq -r '.results[0].id // empty')
if [ -z "$SITE_ID" ]; then
  echo "[!] Netbox site '${site_slug}' not found — run option 6 once first to seed sites/roles"
  exit 1
fi
NET_ROLE_ID=$(nb_create "dcim/device-roles" "slug" "network" \
  '{"name":"Network","slug":"network","color":"2196f3"}')
MFG_ID=$(nb_create "dcim/manufacturers" "slug" "ubiquiti" \
  '{"name":"Ubiquiti","slug":"ubiquiti"}')

echo "$DEVICES" | jq -c '.data[]' | while IFS= read -r dev; do
  DEV_NAME=$(echo "$dev" | jq -r '.name // .hostname // .mac')
  DEV_MODEL=$(echo "$dev" | jq -r '.model // "Unknown"')
  DEV_MODEL_NAME=$(echo "$dev" | jq -r '.model_in_lts // .model_in_eol // .model // "Unknown"')
  DEV_MAC=$(echo "$dev" | jq -r '.mac // ""' | tr 'a-f' 'A-F' | sed 's/\(..\)/\1:/g; s/:$//')
  DEV_IP=$(echo "$dev" | jq -r '.ip // ""')
  DEV_TYPE=$(echo "$dev" | jq -r '.type // "unknown"')
  DEV_VERSION=$(echo "$dev" | jq -r '.version // ""')
  DEV_SERIAL=$(echo "$dev" | jq -r '.serial // ""')

  echo "  [+] $DEV_NAME ($DEV_MODEL) — $DEV_TYPE — $DEV_IP"

  DT_SLUG=$(echo "$DEV_MODEL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')
  DT_ID=$(nb_create "dcim/device-types" "slug" "$DT_SLUG" \
    "{\"manufacturer\":$MFG_ID,\"model\":\"$DEV_MODEL_NAME\",\"slug\":\"$DT_SLUG\"}")

  NB_DEV_ID=$(curl -sk -H "$AUTH" "$API/dcim/devices/?name=$DEV_NAME" | jq -r '.results[0].id // empty')
  if [ -z "$NB_DEV_ID" ]; then
    NB_DEV_ID=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
      -X POST "$API/dcim/devices/" \
      -d "{\"name\":\"$DEV_NAME\",\"device_type\":$DT_ID,\"role\":$NET_ROLE_ID,\"site\":$SITE_ID,\"serial\":\"$DEV_SERIAL\",\"status\":\"active\",\"comments\":\"Firmware: $DEV_VERSION\\nType: $DEV_TYPE\"}" \
      | jq -r '.id // empty')
  else
    curl -sk -H "$AUTH" -H "Content-Type: application/json" \
      -X PATCH "$API/dcim/devices/$NB_DEV_ID/" \
      -d "{\"serial\":\"$DEV_SERIAL\",\"comments\":\"Firmware: $DEV_VERSION\\nType: $DEV_TYPE\"}" > /dev/null
  fi

  [ -z "$NB_DEV_ID" ] && continue

  # Management interface + IP
  MGMT_ID=$(curl -sk -H "$AUTH" "$API/dcim/interfaces/?device_id=$NB_DEV_ID&name=mgmt" | jq -r '.results[0].id // empty')
  if [ -z "$MGMT_ID" ]; then
    MGMT_ID=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
      -X POST "$API/dcim/interfaces/" \
      -d "{\"device\":$NB_DEV_ID,\"name\":\"mgmt\",\"type\":\"1000base-t\",\"mgmt_only\":true}" | jq -r '.id')
  fi

  if [ -n "$DEV_MAC" ] && [ -n "$MGMT_ID" ]; then
    MAC_EXISTS=$(curl -sk -H "$AUTH" "$API/dcim/mac-addresses/?mac_address=$DEV_MAC" | jq -r '.results[0].id // empty')
    if [ -z "$MAC_EXISTS" ]; then
      curl -sk -H "$AUTH" -H "Content-Type: application/json" \
        -X POST "$API/dcim/mac-addresses/" \
        -d "{\"mac_address\":\"$DEV_MAC\",\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$MGMT_ID}" > /dev/null 2>&1
    fi
  fi

  if [ -n "$DEV_IP" ] && [ -n "$MGMT_ID" ]; then
    IP_EXISTS=$(curl -sk -H "$AUTH" "$API/ipam/ip-addresses/?address=$DEV_IP/24" | jq -r '.results[0].id // empty')
    if [ -z "$IP_EXISTS" ]; then
      curl -sk -H "$AUTH" -H "Content-Type: application/json" \
        -X POST "$API/ipam/ip-addresses/" \
        -d "{\"address\":\"$DEV_IP/24\",\"status\":\"active\",\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$MGMT_ID}" > /dev/null
    fi
    IP_ID=$(curl -sk -H "$AUTH" "$API/ipam/ip-addresses/?address=$DEV_IP/24" | jq -r '.results[0].id // empty')
    if [ -n "$IP_ID" ]; then
      curl -sk -H "$AUTH" -H "Content-Type: application/json" \
        -X PATCH "$API/dcim/devices/$NB_DEV_ID/" \
        -d "{\"primary_ip4\":$IP_ID}" > /dev/null
    fi
  fi
done

# --- Networks (VLANs + prefixes) ---
echo "[+] Querying UniFi networks..."
NETWORKS=$(curl -sk -H "X-API-Key: $UNIFI_KEY" \
  "$UNIFI/proxy/network/api/s/$UNIFI_SITE/rest/networkconf" 2>/dev/null)

if echo "$NETWORKS" | jq -e '.meta.rc == "ok"' >/dev/null 2>&1; then
  echo "$NETWORKS" | jq -c '.data[]' | while IFS= read -r net; do
    NET_NAME=$(echo "$net" | jq -r '.name // ""')
    NET_SUBNET=$(echo "$net" | jq -r '.ip_subnet // ""')
    NET_VLAN=$(echo "$net" | jq -r '.vlan // ""')
    NET_PURPOSE=$(echo "$net" | jq -r '.purpose // ""')
    NET_ENABLED=$(echo "$net" | jq -r '.enabled // true')

    [ -z "$NET_NAME" ] && continue
    [ "$NET_ENABLED" = "false" ] && continue

    if [ -n "$NET_VLAN" ] && [ "$NET_VLAN" != "null" ]; then
      VLAN_EXISTS=$(curl -sk -H "$AUTH" "$API/ipam/vlans/" \
        | jq -r --argjson vid "$NET_VLAN" '[.results[] | select(.vid == $vid)][0].id // empty')
      if [ -z "$VLAN_EXISTS" ]; then
        curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X POST "$API/ipam/vlans/" \
          -d "{\"vid\":$NET_VLAN,\"name\":\"$NET_NAME\",\"site\":$SITE_ID,\"status\":\"active\"}" > /dev/null
        echo "  Created VLAN $NET_VLAN ($NET_NAME)"
      fi
    fi

    if [ -n "$NET_SUBNET" ] && [ "$NET_SUBNET" != "null" ]; then
      PREFIX_EXISTS=$(curl -sk -H "$AUTH" "$API/ipam/prefixes/?prefix=$NET_SUBNET" \
        | jq -r '.results[0].id // empty')
      if [ -z "$PREFIX_EXISTS" ]; then
        # Avoid bash default-value syntax inside Nomad heredocs — the
        # colon-dash inside a templatefile-produced interpolation gets
        # rejected by Nomad's HCL2 parser.
        VID_LOOKUP="$NET_VLAN"
        [ -z "$VID_LOOKUP" ] || [ "$VID_LOOKUP" = "null" ] && VID_LOOKUP=0
        VLAN_ID=$(curl -sk -H "$AUTH" "$API/ipam/vlans/" \
          | jq -r --argjson vid "$VID_LOOKUP" '[.results[] | select(.vid == $vid)][0].id // null')
        curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X POST "$API/ipam/prefixes/" \
          -d "{\"prefix\":\"$NET_SUBNET\",\"status\":\"active\",\"site\":$SITE_ID,\"vlan\":$VLAN_ID,\"description\":\"$NET_NAME ($NET_PURPOSE)\"}" > /dev/null
        echo "  Created prefix $NET_SUBNET"
      fi
    fi
  done
fi

echo "[+] Sync complete: $DEVICE_COUNT devices processed"
SCRIPT
        destination = "local/sync.sh"
        perms       = "0755"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
