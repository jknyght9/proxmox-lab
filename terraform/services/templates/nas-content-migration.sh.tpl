#!/bin/bash
# =============================================================================
# Auto-generated NAS content migration script.
# Rendered by terraform/services/nas-content-migrations.tf and uploaded to
# /tmp/nas-migrate.sh on the target TrueNAS host, then executed via cron.
#
# Each migration:
#   1. rsync -av --checksum <source> <destination>
#   2. (if verify_hash) compare SHA-256 manifests of src vs dst
#   3. log result
#
# All output is captured to /tmp/nas-migrate.log. On success, sentinel
# /tmp/nas-migrate.done is created; on any failure, /tmp/nas-migrate.failed.
# =============================================================================
set +e # process all migrations; track failure status, don't stop on first

# Lock guard — prevent multiple cron instances overlapping. Cron is
# scheduled every minute (timezone-agnostic) and the Terraform driver
# deletes it once this script starts; flock provides a safety net for
# the gap between fires.
exec 9>/tmp/nas-migrate.lock
flock -n 9 || exit 0

# Early-exit if already done; manual cleanup required to re-run.
[ -f /tmp/nas-migrate.done ] && exit 0
[ -f /tmp/nas-migrate.failed ] && exit 0

exec > /tmp/nas-migrate.log 2>&1
echo "[START] $(date)"

OVERALL_RC=0

do_migrate() {
  local NAME=$1 SRC=$2 DST=$3 VERIFY=$4
  echo
  echo "=== migrate: $NAME ==="
  echo "    src: $SRC"
  echo "    dst: $DST"

  if [ ! -e "$SRC" ]; then
    echo "[!] $NAME source missing — skipping"
    return 0
  fi

  mkdir -p "$DST"
  if ! rsync -av --checksum "$SRC" "$DST"; then
    echo "[!] $NAME rsync failed"
    OVERALL_RC=1
    return 1
  fi

  if [ "$VERIFY" = "true" ] && [ -d "$SRC" ]; then
    echo "    verifying SHA-256 manifest..."
    (cd "$SRC" && find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null) > /tmp/m-$NAME-src.sha
    (cd "$DST" && find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null) > /tmp/m-$NAME-dst.sha
    if ! diff -q /tmp/m-$NAME-src.sha /tmp/m-$NAME-dst.sha; then
      echo "[!] $NAME hash mismatch"
      diff /tmp/m-$NAME-src.sha /tmp/m-$NAME-dst.sha | head -20
      OVERALL_RC=1
      return 1
    fi
    echo "    [OK] hashes match"
  fi

  echo "[OK] $NAME"
}

%{ for m in migrations ~}
do_migrate '${m.name}' '${m.source}' '${m.destination}' '${m.verify_hash}'
%{ endfor ~}

echo
echo "[END] $(date) rc=$OVERALL_RC"
if [ $OVERALL_RC -eq 0 ]; then
  touch /tmp/nas-migrate.done
else
  touch /tmp/nas-migrate.failed
fi
