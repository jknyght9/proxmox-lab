# CSI node plugin (csi-driver-nfs from kubernetes-sigs).
#
# System job — runs one alloc per Nomad client. This is the side that
# actually issues `mount -t nfs <server>:<path> <local-stage-dir>` when
# Nomad schedules a task that consumes a CSI volume.
#
# Needs:
#   - privileged = true so the container can call mount(2).
#   - bidirectional mount propagation so mounts inside the container
#     become visible to the host, where Nomad bind-mounts them into the
#     consuming task. Nomad's docker driver doesn't have a first-class
#     toggle for this; the volumes block with target_propagation handles
#     it for the in-container CSI staging dir.
#   - NFS client utilities in the image (nfsplugin includes them).

job "csi-node" {
  datacenters = ["dc1"]
  type        = "system"

  group "node" {
    task "node" {
      driver = "docker"

      config {
        image      = "registry.k8s.io/sig-storage/nfsplugin:${csi_driver_nfs_version}"
        privileged = true

        args = [
          "--v=2",
          "--nodeid=$${node.unique.name}",
          "--endpoint=unix:///csi/csi.sock",
          "--mount-permissions=0",
        ]
      }

      csi_plugin {
        id        = "nfs"
        type      = "node"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
