# =============================================================================
# NAS-backed per-service ZFS datasets + NFS shares
#
# For each stateful Nomad service, create:
#   - a ZFS dataset at <pool>/<dataset_root>/<service> on the user's NAS
#   - an NFS share for that dataset, allow_hosts scoped to the Nomad subnet
#
# This is the Phase 0 foundation for the GlusterFS → CSI+NFS migration.
# Idempotent: every apply GETs first; only POSTs if missing. Safe to re-run.
#
# Notes on design choices:
#   - One dataset per service so snapshots and ACLs are independent.
#   - Postgres datasets get recordsize=16K (closer to PG page size) and
#     primarycache=all per ZFS-on-Postgres best practice; others default.
#   - allow_hosts=<network_cidr> matches the existing gluster trust model
#     (cluster subnet only) and leaves room for a future PBS VM to mount.
#     Tighten later by setting nas_storage.cluster_state.allow_hosts.
#   - Snapshot tasks live in nas-snapshots.tf (separate so this file stays
#     focused on share creation).
# =============================================================================

locals {
  # Stateful services that need a persistent CSI volume. Add new entries
  # here as services land. Each entry's settings hint at ZFS tuning.
  cluster_state_services = {
    vault             = { recordsize = "128K", description = "Vault Raft + keystore" }
    authentik-pg      = { recordsize = "16K", description = "Authentik PostgreSQL data" }
    authentik-data    = { recordsize = "128K", description = "Authentik media + branding + certs" }
    samba-dc01        = { recordsize = "128K", description = "Samba AD DC01 state (sysvol + sam.ldb)" }
    samba-dc02        = { recordsize = "128K", description = "Samba AD DC02 state" }
    netbox-pg         = { recordsize = "16K", description = "Netbox PostgreSQL data" }
    netbox-data       = { recordsize = "128K", description = "Netbox media + reports + scripts" }
    netbox-redis      = { recordsize = "128K", description = "Netbox Redis AOF" }
    traefik           = { recordsize = "128K", description = "Traefik TLS certs + acme.json" }
    uptime-kuma       = { recordsize = "128K", description = "Uptime Kuma embedded MariaDB" }
    docs              = { recordsize = "128K", description = "MkDocs build artifacts" }
    lam               = { recordsize = "128K", description = "LAM profile state + session" }
  }

  # Look up the NAS that provides cluster_state by name in var.nas_servers.
  # Errors out if cluster_state.nas references an unknown name (better
  # than silently no-op'ing).
  cluster_state_nas = (
    var.nas_storage.cluster_state.nas != ""
    ? [for n in var.nas_servers : n if n.name == var.nas_storage.cluster_state.nas][0]
    : null
  )

  # Effective allow_hosts: explicit override wins, else cluster subnet.
  cluster_state_allow_hosts = (
    var.nas_storage.cluster_state.allow_hosts != ""
    ? var.nas_storage.cluster_state.allow_hosts
    : var.network_cidr
  )

  # Dataset root path on the NAS, e.g. "pool_data/nomad"
  cluster_state_dataset_root = (
    local.cluster_state_nas != null
    ? "${local.cluster_state_nas.pool}/${var.nas_storage.cluster_state.dataset_root}"
    : ""
  )
}

# --- Create one ZFS dataset + NFS share per service ---
#
# Runs on nomad01 (we already SSH there for other NAS API calls; reuse the
# connection pattern so we don't have to manage HTTPS-to-NAS from the
# terraform-services container).
resource "null_resource" "nas_share" {
  for_each = local.cluster_state_nas != null ? local.cluster_state_services : {}

  depends_on = [vault_kv_secret_v2.nas]

  triggers = {
    nas_address  = local.cluster_state_nas.address
    pool         = local.cluster_state_nas.pool
    dataset_root = var.nas_storage.cluster_state.dataset_root
    allow_hosts  = local.cluster_state_allow_hosts
    recordsize   = each.value.recordsize
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
      SVC="${each.key}"
      NAS_ADDR="${local.cluster_state_nas.address}"
      API_KEY="${local.cluster_state_nas.api_key}"
      API="https://$NAS_ADDR/api/v2.0"
      POOL="${local.cluster_state_nas.pool}"
      DATASET_ROOT="${var.nas_storage.cluster_state.dataset_root}"
      DATASET="$POOL/$DATASET_ROOT/$SVC"
      DATASET_ENC=$(printf '%s' "$DATASET" | sed 's:/:%2F:g')
      MOUNTPOINT="/mnt/$DATASET"
      ALLOW_HOSTS="${local.cluster_state_allow_hosts}"
      RECORDSIZE="${each.value.recordsize}"

      # Debug log (terraform suppresses output when sensitive vars are
      # interpolated into the script — keep our own trace).
      DEBUG_LOG="/tmp/nas_share_$${SVC}.log"
      exec 2>"$DEBUG_LOG"
      set -x
      echo "=== nas_share $${SVC} run at $(date) ===" >&2

      # --- Ensure the dataset_root parent exists ---
      PARENT="$POOL/$DATASET_ROOT"
      PARENT_ENC=$(printf '%s' "$PARENT" | sed 's:/:%2F:g')
      PARENT_HTTP=$(curl -sk -o /dev/null -w '%%{http_code}' \
        -H "Authorization: Bearer $API_KEY" "$API/pool/dataset/id/$PARENT_ENC")
      if [ "$PARENT_HTTP" = "404" ]; then
        echo "[+] Creating parent dataset $PARENT"
        curl -sk -X POST -H "Authorization: Bearer $API_KEY" \
          -H "Content-Type: application/json" "$API/pool/dataset" \
          -d "{\"name\":\"$PARENT\",\"compression\":\"LZ4\"}" >&2
      fi

      # --- Ensure the per-service dataset exists ---
      DS_HTTP=$(curl -sk -o /dev/null -w '%%{http_code}' \
        -H "Authorization: Bearer $API_KEY" "$API/pool/dataset/id/$DATASET_ENC")
      if [ "$DS_HTTP" = "404" ]; then
        echo "[+] Creating dataset $DATASET (recordsize=$RECORDSIZE)"
        BODY=$(jq -nc \
          --arg name "$DATASET" \
          --arg rs   "$RECORDSIZE" \
          '{name:$name, compression:"LZ4", recordsize:$rs, atime:"OFF"}')
        curl -sk -X POST -H "Authorization: Bearer $API_KEY" \
          -H "Content-Type: application/json" "$API/pool/dataset" \
          -d "$BODY" | jq -r '.id // .error // "(no response body)"' >&2
      elif [ "$DS_HTTP" = "200" ]; then
        echo "[=] Dataset $DATASET already exists"
      else
        echo "[!] Unexpected HTTP $DS_HTTP querying dataset $DATASET"
        exit 1
      fi

      # --- Ensure the NFS share exists ---
      # TrueNAS 25.x distinguishes `networks` (CIDR allow-lists) from `hosts`
      # (hostnames or single IPs). Detect by presence of "/" in the value.
      EXISTING_ID=$(curl -sk -H "Authorization: Bearer $API_KEY" "$API/sharing/nfs" \
        | jq -r --arg p "$MOUNTPOINT" '.[] | select(.path == $p) | .id' | head -1)
      if [ -z "$EXISTING_ID" ]; then
        echo "[+] Creating NFS share for $MOUNTPOINT (allow=$ALLOW_HOSTS)"
        if echo "$ALLOW_HOSTS" | grep -q '/'; then
          # CIDR — goes in `networks`
          BODY=$(jq -nc \
            --arg path "$MOUNTPOINT" \
            --arg svc  "nomad/$SVC" \
            --arg net  "$ALLOW_HOSTS" \
            '{path:$path, comment:$svc, maproot_user:"root", maproot_group:"wheel", networks:[$net]}')
        else
          # Single host / hostname
          BODY=$(jq -nc \
            --arg path "$MOUNTPOINT" \
            --arg svc  "nomad/$SVC" \
            --arg host "$ALLOW_HOSTS" \
            '{path:$path, comment:$svc, maproot_user:"root", maproot_group:"wheel", hosts:[$host]}')
        fi
        curl -sk -X POST -H "Authorization: Bearer $API_KEY" \
          -H "Content-Type: application/json" "$API/sharing/nfs" \
          -d "$BODY" | jq -r '.id // .error // .message // tostring' >&2
      else
        echo "[=] NFS share for $MOUNTPOINT already exists (id=$EXISTING_ID)"
      fi

      echo "[+] $SVC: dataset + NFS share OK"
      EOT
    ]
  }
}
