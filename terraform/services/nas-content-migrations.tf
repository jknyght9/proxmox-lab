# =============================================================================
# NAS Content Migrations — one-shot data migration between dataset paths
#
# Renders a per-NAS migration script (rsync + sha256 verification), uploads
# it to nas01:/tmp/nas-migrate.sh via the TrueNAS REST API, schedules a
# one-shot cron job to run it, polls for the success/failure sentinel,
# and fetches the log.
#
# Why cron: TrueNAS 25.x REST has no shell-exec endpoint. cronjob accepts
# arbitrary shell commands and runs them as the specified user (root).
# Scheduling for the next minute fires it immediately; we delete the cron
# after completion so it doesn't re-trigger.
#
# Lab-specific migration list lives in a lab-extensions overlay
# (lab-nas-content-migrations.auto.tfvars).
# =============================================================================

variable "nas_content_migrations" {
  description = "One-shot content migrations: rsync src → dst on a NAS, with optional SHA-256 verification."
  type = list(object({
    nas         = string               # NAS name from var.nas_servers
    name        = string               # short identifier (used in sentinel/log filenames)
    source      = string               # /mnt-prefixed path; trailing slash semantics per rsync
    destination = string               # /mnt-prefixed path
    verify_hash = optional(bool, true) # compare SHA-256 manifest of src vs dst after rsync
  }))
  default = []
}

locals {
  migrations_by_nas = {
    for m in var.nas_content_migrations : m.nas => m...
  }

  migration_scripts = {
    for nas_name, migrations in local.migrations_by_nas : nas_name => templatefile(
      "${path.module}/templates/nas-content-migration.sh.tpl",
      { migrations = migrations }
    )
  }
}

resource "null_resource" "nas_content_migrations" {
  for_each = local.migrations_by_nas

  depends_on = [
    null_resource.nas_classification_datasets,
    null_resource.nas_acls,
  ]

  triggers = {
    migrations_hash = sha256(local.migration_scripts[each.key])
    nas_address     = local.nas_by_name[each.key].address
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e
      NAS_NAME='${each.key}'
      NAS_ADDR='${local.nas_by_name[each.key].address}'
      API_KEY='${local.nas_by_name[each.key].api_key}'
      API="https://$NAS_ADDR/api/v2.0"
      auth() { curl -sk -H "Authorization: Bearer $API_KEY" "$@"; }

      # Write the migration script locally
      SCRIPT_PATH="/tmp/nas-migrate-$NAS_NAME.sh"
      cat > "$SCRIPT_PATH" <<'MIGRATION_SCRIPT_EOF'
${local.migration_scripts[each.key]}
MIGRATION_SCRIPT_EOF

      echo "[+] uploading migration script to $NAS_NAME:/tmp/nas-migrate.sh"
      UPLOAD_RESP=$(auth -X POST "$API/filesystem/put" \
        -F 'data={"path":"/tmp/nas-migrate.sh"};type=application/json' \
        -F "file=@$SCRIPT_PATH")
      echo "    upload resp: $UPLOAD_RESP"

      # Clear any leftover sentinels from prior runs
      for f in nas-migrate.done nas-migrate.failed nas-migrate.log; do
        auth -X POST "$API/filesystem/stat" -H "Content-Type: application/json" -d "\"/tmp/$f\"" \
          | jq -e '.type == "FILE"' >/dev/null 2>&1 && \
          echo "    (leftover /tmp/$f present from prior run — will be overwritten)"
      done

      # Schedule cron every minute — timezone-agnostic (the nas01 cron
      # daemon uses local time; computing the exact next-minute on
      # nomad01 risks a timezone mismatch). The cron's command first
      # rm's any leftover sentinels (.done/.failed/.log/.lock) from
      # prior runs and touches a fresh .cleared marker, then runs the
      # script. The script has a flock guard + .done/.failed early-exit
      # so overlapping fires are safe, and we delete the cron as soon
      # as the .cleared marker appears with a fresh mtime.
      #
      # We must NOT detect "script started" via the .log file alone —
      # the script's first action is `exec > /tmp/nas-migrate.log`,
      # but a stale .log from a prior run would also satisfy that check
      # and cause us to delete the cron before it ever fires.
      NOW_EPOCH=$(date +%s)
      echo "[+] scheduling cron (every minute, deleted on first fire)"
      CRON_CMD='rm -f /tmp/nas-migrate.failed /tmp/nas-migrate.done /tmp/nas-migrate.log /tmp/nas-migrate.lock /tmp/nas-migrate.cleared && touch /tmp/nas-migrate.cleared && bash /tmp/nas-migrate.sh'
      CRON_RESP=$(auth -X POST "$API/cronjob" -H "Content-Type: application/json" \
        -d "$(jq -n --arg cmd "$CRON_CMD" '{
          command: $cmd,
          user: "root",
          enabled: true,
          stdout: true,
          stderr: true,
          schedule: {minute: "*", hour: "*", dom: "*", month: "*", dow: "*"}
        }')")
      CRON_ID=$(echo "$CRON_RESP" | jq -r '.id // empty')
      if [ -z "$CRON_ID" ]; then
        echo "[!] cron create failed: $CRON_RESP"
        exit 1
      fi
      echo "    cron id=$CRON_ID"

      # Wait for a FRESH .cleared marker (mtime > NOW_EPOCH) — proves
      # the cron actually fired this minute, not a stale marker.
      echo "[+] waiting for fresh .cleared marker..."
      for i in $(seq 1 24); do
        MTIME=$(auth -X POST "$API/filesystem/stat" -H "Content-Type: application/json" \
          -d '"/tmp/nas-migrate.cleared"' | jq -r '.mtime // 0' | cut -d. -f1)
        if [ "$MTIME" -gt "$NOW_EPOCH" ]; then
          echo "    script started (cleared at $MTIME, scheduled at $NOW_EPOCH)"
          break
        fi
        sleep 5
      done

      # Delete the cron immediately so it doesn't re-fire while the
      # script is running. The flock guard would prevent overlap anyway,
      # but cleaner to remove the trigger.
      echo "[+] deleting cron $CRON_ID (script is now running)"
      auth -X DELETE "$API/cronjob/id/$CRON_ID" >/dev/null 2>&1 || true

      # Poll for completion (max ~4h)
      echo "[+] waiting for migration..."
      STATUS=""
      for i in $(seq 1 480); do
        if auth -X POST "$API/filesystem/stat" -H "Content-Type: application/json" \
            -d '"/tmp/nas-migrate.done"' | jq -e '.type == "FILE"' >/dev/null 2>&1; then
          STATUS="done"; break
        fi
        if auth -X POST "$API/filesystem/stat" -H "Content-Type: application/json" \
            -d '"/tmp/nas-migrate.failed"' | jq -e '.type == "FILE"' >/dev/null 2>&1; then
          STATUS="failed"; break
        fi
        # progress hint every 5 minutes
        if [ $((i % 10)) -eq 0 ]; then
          echo "    still waiting (elapsed ~$((i * 30))s)"
        fi
        sleep 30
      done

      # Fetch log (best-effort)
      echo "[+] migration log:"
      auth -X POST "$API/filesystem/get" -H "Content-Type: application/json" \
        -d '"/tmp/nas-migrate.log"' 2>&1 | head -200 || true

      # Cron was already deleted right after the script started; nothing
      # to clean up here.

      case "$STATUS" in
        done)
          echo "[+] $NAS_NAME migration complete"
          ;;
        failed)
          echo "[!] $NAS_NAME migration FAILED — see log above"
          exit 1
          ;;
        *)
          echo "[!] $NAS_NAME migration TIMEOUT (4h) — script may still be running on the NAS; check /tmp/nas-migrate.log"
          exit 1
          ;;
      esac
      EOT
    ]
  }
}
