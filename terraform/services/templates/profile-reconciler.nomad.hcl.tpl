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

# NetBIOS/workgroup name = first label of the realm, uppercased
# (e.g. iotvf.lab -> IOTVF). Used to qualify principals in NFSv4 ACLs as
# WORKGROUP\name, matching the nas-acls.tf / nas-profile-share.tf format.
WORKGROUP=$(echo "$AD_REALM_LOWER" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')

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

# Iterate with a for-loop (not `echo | while`): a pipe runs the loop body
# in a subshell, so CREATED/EXISTED/FAILED increments would be lost and the
# summary below would always print 0/0/0. sAMAccountName cannot contain
# spaces, so word-splitting $USERS is safe.
for USER in $USERS; do
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
  # NFS4ACE uses `who` (qualified WORKGROUP\name, lowercased), not `name`.
  ACL=$(jq -n --arg p "$USER_PATH" --arg u "$USER" --arg wg "$WORKGROUP" '
    def qualify($n):
      if ($wg != "" and ($n | test("[\\\\@]") | not) and ($n != "CREATOR OWNER"))
      then "\($wg)\\\($n | ascii_downcase)" else $n end;
    {
    path: $p,
    dacl: [
      {tag:"USER",  id:null, who: qualify($u),              type:"ALLOW",
        perms:{BASIC:"FULL_CONTROL"},
        flags:{DIRECTORY_INHERIT:true, FILE_INHERIT:true}},
      {tag:"GROUP", id:null, who: qualify("Domain Admins"), type:"ALLOW",
        perms:{BASIC:"FULL_CONTROL"},
        flags:{DIRECTORY_INHERIT:true, FILE_INHERIT:true}}
    ],
    options: {stripacl:false, recursive:false, traverse:false},
    acltype: "NFS4"
  }')

  SETACL_JOB=$(auth -X POST -H "Content-Type: application/json" \
    "$API/filesystem/setacl" -d "$ACL")

  # setacl can return either a job id (async) or an error object.
  # busybox ash (alpine) has no [[ =~ ]] — use a POSIX numeric test.
  if printf '%s' "$SETACL_JOB" | grep -qE '^[0-9]+$'; then
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
