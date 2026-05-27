# CSI controller plugin (csi-driver-nfs from kubernetes-sigs).
#
# Single-instance service job. Talks to no external storage backend by
# itself — for static NFS shares, all the work happens on the node side
# at mount time. The controller exists so Nomad can validate volume
# registration (capabilities, plugin health) and so we can later swap
# in a CSI driver that DOES need centralized provisioning (e.g.,
# democratic-csi for TrueNAS-API-driven volume create/delete) without
# changing the consuming jobs.
#
# See https://github.com/kubernetes-csi/csi-driver-nfs for upstream.

job "csi-controller" {
  datacenters = ["dc1"]
  type        = "service"

  group "controller" {
    count = 1

    # Pin to nomad01 so log scraping / restart semantics match other
    # service jobs in this repo. Could be unpinned (controller is
    # stateless) but consistency is cheap.
    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    task "controller" {
      driver = "docker"

      config {
        image = "registry.k8s.io/sig-storage/nfsplugin:${csi_driver_nfs_version}"

        # nfsplugin is the same binary for controller and node; mode is
        # implied by which CSI services we expose (ControllerService for
        # this alloc). --mount-permissions=0 leaves dir perms to the
        # service's own setup (we don't want CSI clobbering AD ACLs etc).
        args = [
          "--v=2",
          "--nodeid=$${NOMAD_ALLOC_ID}",
          "--endpoint=unix:///csi/csi.sock",
          "--mount-permissions=0",
        ]

        # Privileged not strictly needed for the controller (no mounts),
        # but the upstream image expects it. Keep aligned with the node
        # plugin so the docker driver doesn't reject one and accept
        # the other on capability handling differences.
        privileged = true
      }

      csi_plugin {
        id        = "nfs"
        type      = "controller"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
