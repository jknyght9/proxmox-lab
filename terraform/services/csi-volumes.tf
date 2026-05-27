# =============================================================================
# CSI volume registrations — one per stateful service migrated off GlusterFS
#
# Each `nomad_csi_volume_registration` resource here tells Nomad about a
# pre-existing NFS share (created by null_resource.nas_share in
# nas-shares.tf) so service jobs can consume it via `volume "data" {}`
# stanzas. csi-driver-nfs doesn't implement CreateVolume — we register
# only — which is fine because the share was provisioned in Phase 0.
#
# Migration is per-service so this file grows one resource at a time as
# we cut services over. Order tracks plans/serene-brewing-cray.md Phase 2.
# =============================================================================

locals {
  csi_server = local.cluster_state_nas != null ? local.cluster_state_nas.address : ""
}

# Helper that other modules might want one day. Centralizes the share-path
# construction so we don't repeat "/mnt/<pool>/<dataset_root>/<svc>" in N
# places. Not used by anything else yet but worth keeping.
locals {
  csi_share_path = {
    for k, _ in local.cluster_state_services :
    k => "/mnt/${local.cluster_state_dataset_root}/${k}"
  }
}

# --- uptime-kuma ------------------------------------------------------------
resource "nomad_csi_volume_registration" "uptime_kuma" {
  count = var.deploy_csi && var.deploy_uptime_kuma ? 1 : 0

  depends_on = [
    nomad_job.csi_controller,
    nomad_job.csi_node,
    null_resource.nas_share,
  ]

  plugin_id   = "nfs"
  volume_id   = "uptime-kuma-data"
  name        = "uptime-kuma-data"
  # csi-driver-nfs uses external_id as the volume handle for static
  # registrations. Convention: <server>#<share>#<nfs-version>.
  external_id = "${local.csi_server}#${local.csi_share_path["uptime-kuma"]}#"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  parameters = {
    server = local.csi_server
    share  = local.csi_share_path["uptime-kuma"]
  }

  context = {
    server = local.csi_server
    share  = local.csi_share_path["uptime-kuma"]
  }

  mount_options {
    fs_type     = "nfs"
    mount_flags = ["nfsvers=4.1", "hard"]
  }
}
