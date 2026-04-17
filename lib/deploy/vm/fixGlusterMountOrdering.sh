#!/usr/bin/env bash

# fixGlusterMountOrdering.sh - Apply the GlusterFS mount-race fix to running
# Nomad nodes without a Packer rebuild.
#
# On every Nomad node:
#  1. Rewrite /etc/fstab so the gluster mount waits for glusterd and is
#     marked nofail (idempotent — replaces the old line if present).
#  2. Drop /etc/systemd/system/docker.service.d/wait-gluster.conf and
#     /etc/systemd/system/nomad.service.d/wait-gluster.conf so those
#     services require the gluster mount (RequiresMountsFor).
#  3. Enable the raw_exec driver in /etc/nomad.d/nomad.hcl so per-job
#     prestart guards can stat the host-side sentinel cheaply.
#  4. systemctl daemon-reload, mount the volume if needed, and write the
#     .mount-sentinel marker.
#
# This is the runtime equivalent of the changes baked into the Packer
# template and cloud-init on this branch. Safe to re-run.
#
# Globals read: VM_USER, NOMAD_DATA_DIR, GLUSTER_VOLUME
function fixGlusterMountOrdering() {
  cat <<EOF

############################################################################
GlusterFS Mount-Race Fix (one-shot)

Sequences the gluster mount before Docker / Nomad on every boot so jobs
never bind-mount a pre-mount empty local directory. Applies to the nodes
currently in hosts.json.
#############################################################################

EOF

  if [ ! -f hosts.json ]; then
    error "hosts.json not found — deploy the Nomad cluster first."
    return 1
  fi

  local NOMAD_IPS
  NOMAD_IPS=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  if [ -z "$NOMAD_IPS" ]; then
    error "No nomad* hosts found in hosts.json"
    return 1
  fi

  local MOUNTPOINT="$NOMAD_DATA_DIR"
  local VOL="$GLUSTER_VOLUME"
  local FSTAB_LINE="localhost:/${VOL} ${MOUNTPOINT} glusterfs defaults,_netdev,nofail,x-systemd.requires=glusterd.service,x-systemd.after=glusterd.service 0 0"

  local FIRST_NODE=""
  local ip
  for ip in $NOMAD_IPS; do
    [ -z "$FIRST_NODE" ] && FIRST_NODE="$ip"
    info "Applying fix on $ip"

    # 1. Rewrite fstab (replace any existing gluster line).
    doing "  Updating /etc/fstab"
    sshRunAdmin "$VM_USER" "$ip" \
      "sudo sed -i '\|^localhost:/${VOL}[[:space:]]|d' /etc/fstab && echo '$FSTAB_LINE' | sudo tee -a /etc/fstab >/dev/null"

    # 2. Install systemd drop-ins.
    doing "  Installing docker/nomad systemd drop-ins"
    sshRunAdmin "$VM_USER" "$ip" "sudo mkdir -p /etc/systemd/system/docker.service.d /etc/systemd/system/nomad.service.d"
    sshRunAdmin "$VM_USER" "$ip" \
      "printf '[Unit]\\nRequiresMountsFor=${MOUNTPOINT}\\n' | sudo tee /etc/systemd/system/docker.service.d/wait-gluster.conf >/dev/null"
    sshRunAdmin "$VM_USER" "$ip" \
      "printf '[Unit]\\nRequiresMountsFor=${MOUNTPOINT}\\n' | sudo tee /etc/systemd/system/nomad.service.d/wait-gluster.conf >/dev/null"

    # 3. Enable raw_exec in nomad.hcl if not already there.
    doing "  Ensuring raw_exec driver is enabled"
    sshRunAdmin "$VM_USER" "$ip" '
      if ! sudo grep -q "plugin \"raw_exec\"" /etc/nomad.d/nomad.hcl; then
        sudo tee -a /etc/nomad.d/nomad.hcl >/dev/null <<RAWEXEC

# Added by fixGlusterMountOrdering: enables prestart mount guards.
plugin "raw_exec" {
  config {
    enabled = true
  }
}
RAWEXEC
      fi
    '

    # 4. daemon-reload so the new generated mount unit + drop-ins take effect.
    doing "  systemctl daemon-reload"
    sshRunAdmin "$VM_USER" "$ip" "sudo systemctl daemon-reload"

    # Make sure the volume is mounted now (in case it wasn't already).
    sshRunAdmin "$VM_USER" "$ip" "mountpoint -q '$MOUNTPOINT' || sudo mount '$MOUNTPOINT'"

    success "  $ip ready"
  done

  # Write the sentinel through the first node — gluster replicates it.
  doing "Writing mount sentinel at ${MOUNTPOINT}/.mount-sentinel"
  sshRunAdmin "$VM_USER" "$FIRST_NODE" \
    "printf 'v1\\n' | sudo tee '${MOUNTPOINT}/.mount-sentinel' >/dev/null && sudo chmod 644 '${MOUNTPOINT}/.mount-sentinel'"

  # Restart Nomad so the new raw_exec plugin loads.
  doing "Restarting Nomad on each node to pick up raw_exec driver"
  for ip in $NOMAD_IPS; do
    sshRunAdmin "$VM_USER" "$ip" "sudo systemctl restart nomad"
  done

  success "GlusterFS mount-ordering fix applied to ${NOMAD_IPS//$'\n'/ }"
  echo
  info "Verify on next reboot:"
  info "  systemctl list-dependencies docker.service | grep gluster"
  info "  mountpoint /srv/gluster/nomad-data   # should report 'is a mountpoint'"
  info "  test -f /srv/gluster/nomad-data/.mount-sentinel && echo OK"
}
