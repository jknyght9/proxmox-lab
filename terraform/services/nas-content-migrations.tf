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

      # Schedule cron for ~90s in the future so it fires on the next minute boundary
      MIN=$(date -d '+90 seconds' +%-M)
      HOUR=$(date -d '+90 seconds' +%-H)
      DOM=$(date -d '+90 seconds' +%-d)
      MON=$(date -d '+90 seconds' +%-m)
      echo "[+] scheduling cron for $HOUR:$MIN on $MON-$DOM"

      CRON_PAYLOAD=$(jq -n --arg cmd "bash /tmp/nas-migrate.sh" \
        --arg min "$MIN" --arg hr "$HOUR" --arg dom "$DOM" --arg mon "$MON" '{
          command: $cmd,
          user: "root",
          enabled: true,
          stdout: true,
          stderr: true,
          schedule: {minute: $min, hour: $hr, dom: $dom, month: $mon, dow: "*"}
        }')
      CRON_RESP=$(auth -X POST "$API/cronjob" -H "Content-Type: application/json" -d "$CRON_PAYLOAD")
      CRON_ID=$(echo "$CRON_RESP" | jq -r '.id // empty')
      if [ -z "$CRON_ID" ]; then
        echo "[!] cron create failed: $CRON_RESP"
        exit 1
      fi
      echo "    cron id=$CRON_ID"

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

      # Always remove the cron job (it would re-fire next year otherwise)
      echo "[+] cleanup: removing cron $CRON_ID"
      auth -X DELETE "$API/cronjob/id/$CRON_ID" >/dev/null 2>&1 || true

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
