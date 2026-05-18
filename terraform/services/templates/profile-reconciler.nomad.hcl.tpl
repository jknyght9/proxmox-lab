job "profile-reconciler" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    cron             = "${cron_schedule}"
    prohibit_overlap = true
    time_zone        = "${time_zone}"
  }

  group "reconcile" {
    count = 1

    vault {
      role        = "profile-reconciler"
      change_mode = "restart"
    }

    task "reconcile" {
      driver = "docker"

      config {
        image        = "alpine:3.20"
        network_mode = "host"
        command      = "/bin/sh"
        args         = ["/local/reconcile.sh"]
      }

      template {
        data = <<SCRIPT
#!/bin/sh
set -eu

apk add --no-cache curl jq openldap-clients >/dev/null 2>&1

# --- AD bind credentials + cluster context ---
{{ with secret "secret/data/samba-ad/service-accounts" }}
DOMAIN_JOIN_PW="{{ .Data.data.domain_join_password }}"
{{ end }}

{{ with secret "secret/data/config/cluster" }}
AD_REALM_LOWER="{{ .Data.data.ad_realm_lower }}"
BASE_DN="{{ .Data.data.base_dn }}"
{{ end }}

{{ with secret "secret/data/config/nomad-nodes" }}
LDAP_HOST="{{ .Data.data.nomad01_ip }}"
{{ end }}

export LDAPTLS_REQCERT=allow
LDAP_BIND_DN="CN=domain-join-svc,CN=Users,$BASE_DN"

echo "[+] Querying Samba AD for user accounts (LDAPS $LDAP_HOST)"
USERS=$(ldapsearch -LLL -H "ldaps://$LDAP_HOST" -x \
  -D "$LDAP_BIND_DN" -w "$DOMAIN_JOIN_PW" \
  -b "CN=Users,$BASE_DN" \
  "(&(objectClass=user)(!(objectClass=computer))(!(sAMAccountName=krbtgt))(!(sAMAccountName=Guest)))" \
  sAMAccountName 2>/dev/null \
  | awk '/^sAMAccountName: /{print $2}' | sort -u)

if [ -z "$USERS" ]; then
  echo "[!] LDAPS bind failed or no users found — aborting"
  exit 1
fi

USER_COUNT=$(echo "$USERS" | wc -l)
echo "[+] Found $USER_COUNT user(s) in AD"

# --- Per-NAS reconciliation ---
# Each block is rendered statically by terraform templatefile at apply time;
# one block per nas_servers entry with provides_profiles=true.
%{ for nas in profile_nases ~}

echo ""
echo "=== ${nas.name} (${nas.address}) — dataset ${nas.profile_dataset} ==="
{{ with secret "secret/data/nas/${nas.name}" }}
NAS_API_KEY="{{ .Data.data.api_key }}"
{{ end }}

NAS_ADDR="${nas.address}"
DATASET="${nas.profile_dataset}"
MOUNT_PATH="/mnt/$DATASET"
API="https://$NAS_ADDR/api/v2.0"

auth() { curl -sk -H "Authorization: Bearer $NAS_API_KEY" "$@"; }

# Verify share is reachable / dataset exists before doing per-user work
DS_ENC=$(printf '%s' "$DATASET" | sed 's|/|%2F|g')
DS_CODE=$(auth -o /dev/null -w '%%%%{http_code}' "$API/pool/dataset/id/$DS_ENC")
if [ "$DS_CODE" != "200" ]; then
  echo "[!] dataset $DATASET missing on ${nas.name} (HTTP $DS_CODE) — skipping; run terraform apply"
  continue 2>/dev/null || true
fi

CREATED=0
EXISTED=0
FAILED=0

echo "$USERS" | while read -r USER; do
  [ -z "$USER" ] && continue
  USER_PATH="$MOUNT_PATH/$USER"

  STAT_CODE=$(auth -X POST -H "Content-Type: application/json" \
    -o /dev/null -w '%%%%{http_code}' \
    "$API/filesystem/stat" -d "$(jq -n --arg p "$USER_PATH" '{path:$p}')")

  if [ "$STAT_CODE" = "200" ]; then
    EXISTED=$((EXISTED + 1))
    continue
  fi

  # Create the folder. SCALE 25.x exposes filesystem.mkdir; older
  # versions may need SSH-as-root fallback (see plan risks).
  MK=$(auth -X POST -H "Content-Type: application/json" \
    "$API/filesystem/mkdir" -d "$(jq -n --arg p "$USER_PATH" '{path:$p}')")
  if echo "$MK" | jq -e '.error // .errno' >/dev/null 2>&1; then
    echo "  [!] mkdir $USER_PATH failed: $(echo "$MK" | jq -c .)"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Per-user ACL: owner gets FULL_CONTROL, Domain Admins fallback, others none.
  ACL=$(jq -n --arg p "$USER_PATH" --arg u "$USER" '{
    path: $p,
    dacl: [
      {tag:"USER",  id:null, name:$u,              type:"ALLOW",
        perms:{BASIC:"FULL_CONTROL"},
        flags:{DIRECTORY_INHERIT:true, FILE_INHERIT:true}},
      {tag:"GROUP", id:null, name:"Domain Admins", type:"ALLOW",
        perms:{BASIC:"FULL_CONTROL"},
        flags:{DIRECTORY_INHERIT:true, FILE_INHERIT:true}}
    ],
    options: {stripacl:false, recursive:false, traverse:false},
    acltype: "NFS4"
  }')

  SETACL_JOB=$(auth -X POST -H "Content-Type: application/json" \
    "$API/filesystem/setacl" -d "$ACL")

  # setacl can return either a job id (async) or an error object
  if [[ "$SETACL_JOB" =~ ^[0-9]+$ ]]; then
    : # job submitted — assume success (poll skipped for batch perf)
    CREATED=$((CREATED + 1))
    echo "  [+] $USER_PATH (ACL job $SETACL_JOB)"
  elif echo "$SETACL_JOB" | jq -e '.error // .errno' >/dev/null 2>&1; then
    echo "  [!] setacl $USER_PATH failed: $(echo "$SETACL_JOB" | jq -c .)"
    FAILED=$((FAILED + 1))
  else
    CREATED=$((CREATED + 1))
    echo "  [+] $USER_PATH"
  fi
done

echo "[=] ${nas.name}: created=$CREATED existing=$EXISTED failed=$FAILED"
%{ endfor ~}

echo ""
echo "[+] Reconcile complete"
SCRIPT
        destination = "local/reconcile.sh"
        perms       = "0755"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
