#!/usr/bin/env bash
# =============================================================================
# Cluster backup job — pool-scoped vzdump/PBS schedule
#
# Why bash and not Terraform: a backup job is a cluster-level Proxmox object
# (/cluster/backup), and the bpg provider exposes no resource for it. The
# project already owns cluster-level config in bash (API user/role, node DNS,
# purge), so this sits with those rather than behind a null_resource shelling
# out from Terraform.
#
# Terraform owns the POOL OBJECT (terraform/pool.tf); this file owns both the
# MEMBERSHIP (ensurePoolMembership) and the SCHEDULE (configureBackupJob).
# Idempotent: the job is identified by a marker in its comment, so re-running
# updates in place instead of duplicating.
#
# Reads from bootstrap.yml:
#   resource_pool
#   pve_backup.enabled | .storage | .schedule | .mode
#   pve_backup.retention.keep_daily | .keep_weekly | .keep_monthly | .keep_last
# =============================================================================

BACKUP_JOB_MARKER="managed-by:proxmox-lab"

# Find our job's id, or empty. Matches on the marker, never on schedule or
# storage — those are the things the user may change.
function _findBackupJobId() {
  local host="$1"
  sshRun "$REMOTE_USER" "$host" \
    "pvesh get /cluster/backup --output-format json 2>/dev/null" 2>/dev/null \
    | python3 -c "
import sys, json
try:    jobs = json.load(sys.stdin)
except Exception: sys.exit(0)
for j in jobs:
    if '${BACKUP_JOB_MARKER}' in (j.get('comment') or ''):
        print(j.get('id', '')); break
" 2>/dev/null
}

# Add every guest this project deployed to the resource pool.
#
# Membership is applied here rather than via the provider's pool_id, which is
# unusable on cloned guests: the provider sets the pool during the clone and
# then PUTs it again, so Proxmox returns "already a pool member" (HTTP 500) and
# the resource errors after the guest exists — leaving a VM that is in the pool
# but missing from Terraform state.
#
# Idempotent: only VMIDs that are not already members are added, so re-running
# a deploy is a no-op. --allow-move is NOT passed, so a guest deliberately
# placed in another pool is left alone and reported instead of being hijacked.
function ensurePoolMembership() {
  local host="${1:-$PROXMOX_HOST}"
  local pool
  pool=$(yq -r '.resource_pool // ""' "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)
  [ -z "$pool" ] && return 0

  # Everything this project deploys, per lib/constants.sh.
  local candidates="${VMID_NOMAD_START}-${VMID_NOMAD_END} ${VMID_DNS_START}-${VMID_DNS_END} ${VMID_KASM}"
  local want=""
  local range
  for range in $candidates; do
    if [[ "$range" == *-* ]]; then
      local lo="${range%-*}" hi="${range#*-}" i
      for ((i=lo; i<=hi; i++)); do want="$want $i"; done
    else
      want="$want $range"
    fi
  done

  local existing_json
  existing_json=$(sshRun "$REMOTE_USER" "$host" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" 2>/dev/null)
  [ -z "$existing_json" ] && { warn "Could not read cluster resources — skipping pool membership"; return 0; }

  local to_add=() elsewhere=() vmid
  for vmid in $want; do
    local state
    state=$(printf '%s' "$existing_json" | python3 -c "
import sys, json
try:    rs = json.load(sys.stdin)
except Exception: sys.exit(0)
for r in rs:
    if r.get('vmid') == $vmid:
        print(r.get('pool') or 'none'); break
" 2>/dev/null)
    case "$state" in
      "")      : ;;                       # guest does not exist — nothing to do
      none)    to_add+=("$vmid") ;;
      "$pool") : ;;                       # already correct
      *)       elsewhere+=("$vmid:$state") ;;
    esac
  done

  if [ ${#elsewhere[@]} -gt 0 ]; then
    warn "Not moving guests already in another pool: ${elsewhere[*]}"
  fi
  if [ ${#to_add[@]} -eq 0 ]; then
    info "  Pool '$pool': membership already correct"
    return 0
  fi

  local csv; csv=$(IFS=,; echo "${to_add[*]}")
  doing "Adding to pool '$pool': $csv"
  sshRun "$REMOTE_USER" "$host" "pvesh set /pools/$pool --vms $csv" >/dev/null 2>&1 \
    && success "Pool membership updated" \
    || { error "Failed adding $csv to pool $pool"; return 1; }
  return 0
}

function configureBackupJob() {
  local host="${1:-$PROXMOX_HOST}"

  if ! command -v yq >/dev/null 2>&1; then
    warn "yq not found — skipping backup job configuration"
    return 0
  fi

  local pool enabled storage schedule mode
  pool=$(yq -r '.resource_pool // ""' "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)
  enabled=$(yq -r '.pve_backup.enabled // false' "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)
  storage=$(yq -r '.pve_backup.storage // ""' "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)
  schedule=$(yq -r '.pve_backup.schedule // "03:00"' "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)
  mode=$(yq -r '.pve_backup.mode // "snapshot"' "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)

  local existing; existing=$(_findBackupJobId "$host")

  # Disabled (or never configured) — tear down a job we previously created so
  # flipping enabled:false actually stops backups instead of orphaning them.
  if [ "$enabled" != "true" ]; then
    if [ -n "$existing" ]; then
      doing "pve_backup disabled — removing the managed backup job..."
      sshRun "$REMOTE_USER" "$host" "pvesh delete /cluster/backup/$existing" >/dev/null 2>&1 \
        && success "Backup job removed" \
        || warn "Could not remove backup job $existing"
    fi
    return 0
  fi

  if [ -z "$pool" ]; then
    error "pve_backup.enabled is true but resource_pool is unset — a pool-scoped job needs one"
    return 1
  fi
  if [ -z "$storage" ]; then
    error "pve_backup.enabled is true but pve_backup.storage is unset (e.g. a PBS storage id)"
    return 1
  fi

  # Storage must exist and accept backups, or the job is created and then
  # fails silently every night.
  if ! sshRun "$REMOTE_USER" "$host" \
      "pvesm status --storage '$storage' 2>/dev/null | tail -n +2 | grep -q ." 2>/dev/null; then
    error "Backup storage '$storage' not found on the cluster"
    return 1
  fi

  # Retention is optional: when no keep_* is given, the storage's own
  # prune policy applies (PBS prune jobs, or storage-level prune-backups).
  local retention="" k
  for k in last hourly daily weekly monthly yearly; do
    local v; v=$(yq -r ".pve_backup.retention.keep_${k} // \"\"" "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)
    [ -n "$v" ] && [ "$v" != "null" ] && retention="${retention}keep-${k}=${v},"
  done
  retention="${retention%,}"

  local args="--schedule '$schedule' --storage '$storage' --mode '$mode'"
  args="$args --pool '$pool' --enabled 1"
  args="$args --comment 'proxmox-lab pool \"$pool\" -> $storage | $BACKUP_JOB_MARKER'"
  [ -n "$retention" ] && args="$args --prune-backups '$retention'"

  if [ -n "$existing" ]; then
    doing "Updating backup job (pool=$pool -> $storage, $schedule)..."
    sshRun "$REMOTE_USER" "$host" "pvesh set /cluster/backup/$existing $args" >/dev/null 2>&1 \
      && success "Backup job updated" \
      || { error "Failed to update backup job $existing"; return 1; }
  else
    doing "Creating backup job (pool=$pool -> $storage, $schedule)..."
    sshRun "$REMOTE_USER" "$host" "pvesh create /cluster/backup $args" >/dev/null 2>&1 \
      && success "Backup job created" \
      || { error "Failed to create backup job"; return 1; }
  fi

  info "  Scope:     pool '$pool' (membership applied by ensurePoolMembership)"
  info "  Storage:   $storage"
  info "  Schedule:  $schedule  (systemd calendar event — '03:00', not 'daily 03:00')"
  [ -n "$retention" ] && info "  Retention: $retention" \
    || info "  Retention: inherited from the storage's own prune policy"
  return 0
}

# Called by the purge path — removes only a job carrying our marker.
function removeBackupJob() {
  local host="${1:-$PROXMOX_HOST}"
  local existing; existing=$(_findBackupJobId "$host")
  if [ -n "$existing" ]; then
    sshRun "$REMOTE_USER" "$host" "pvesh delete /cluster/backup/$existing" >/dev/null 2>&1 \
      && info "  Removed managed backup job" \
      || warn "  Could not remove backup job $existing"
  fi
}
