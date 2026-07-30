# =============================================================================
# Nomad Jobs — deployed via Terraform nomad provider
# Replaces: all deployNomadJob SCP+SSH calls in lib/deploy/nomadJob/*.sh
# =============================================================================

resource "nomad_job" "traefik" {
  count = var.deploy_traefik ? 1 : 0
  depends_on = [
    null_resource.nomad_vault_config,
    vault_policy.traefik,
    vault_jwt_auth_backend_role.traefik,
    vault_pki_secret_backend_role.acme_certs,
  ]

  jobspec = templatefile("${path.module}/templates/traefik.nomad.hcl.tpl", {
    dns_server  = var.dns_server_ip
    dns_postfix = var.dns_postfix
    nomad01_ip  = local.nomad01_ip
    nomad_ips   = [for _, ip in var.nomad_node_ips : ip]
    dns01_ip    = var.dns_server_ip
  })
  detach = false
}

resource "nomad_job" "authentik" {
  count = var.deploy_authentik ? 1 : 0
  depends_on = [
    vault_policy.authentik,
    vault_jwt_auth_backend_role.authentik,
    vault_kv_secret_v2.authentik,
    null_resource.nomad_vault_config,
    nomad_csi_volume_registration.authentik_pg,
    nomad_csi_volume_registration.authentik_data,
  ]

  jobspec = templatefile("${path.module}/templates/authentik.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false

  # First-run pulls postgres + authentik server + worker (~600MB total)
  # and runs initial DB migrations. Default 5m wait isn't enough on
  # most lab connections.
  timeouts {
    create = "20m"
    update = "20m"
  }
}

resource "nomad_job" "samba_ad" {
  count = var.deploy_samba_ad ? 1 : 0
  depends_on = [
    null_resource.samba_directories,
    vault_policy.samba_ad,
    vault_jwt_auth_backend_role.samba_ad,
    vault_kv_secret_v2.samba_ad,
    vault_kv_secret_v2.cluster_config,
    vault_kv_secret_v2.nomad_nodes,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/samba-ad.nomad.hcl.tpl", {
    ad_realm = var.ad_realm
  })
  detach = false

  # First-run provisions the AD directory (samba-tool domain provision)
  # which is slow on top of the image pull. 5m is too tight.
  timeouts {
    create = "20m"
    update = "15m"
  }
}

resource "nomad_job" "uptime_kuma" {
  count = var.deploy_uptime_kuma ? 1 : 0
  depends_on = [
    null_resource.nomad_vault_config,
    nomad_csi_volume_registration.uptime_kuma,
  ]

  jobspec = templatefile("${path.module}/templates/uptime-kuma.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false
}

resource "nomad_job" "lam" {
  count = var.deploy_lam ? 1 : 0
  depends_on = [
    vault_policy.lam,
    vault_jwt_auth_backend_role.lam,
    vault_kv_secret_v2.cluster_config,
    null_resource.nomad_vault_config,
    null_resource.lam_bootstrap,
    nomad_csi_volume_registration.lam_config,
    nomad_csi_volume_registration.lam_profile,
    nomad_csi_volume_registration.lam_session,
  ]

  jobspec = templatefile("${path.module}/templates/lam.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false
}

# Removed: nomad_job.backup. The explicit tar+pg_dump backup Nomad job
# was replaced in Phase 2/3 by ZFS snapshots on the cluster_state NAS
# (configured via storage.snapshots in bootstrap.yml). See
# plans/serene-brewing-cray.md. The bootstrap.yml `backup:` block is
# also deprecated; existing entries are ignored by the tfvars generator.

resource "nomad_job" "netbox" {
  count = var.deploy_netbox ? 1 : 0
  depends_on = [
    vault_policy.netbox,
    vault_jwt_auth_backend_role.netbox,
    vault_kv_secret_v2.netbox,
    null_resource.nomad_vault_config,
    nomad_csi_volume_registration.netbox_pg,
    nomad_csi_volume_registration.netbox_redis,
    nomad_csi_volume_registration.netbox_data,
  ]

  jobspec = templatefile("${path.module}/templates/netbox.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false

  # First-run pulls postgres:17 + redis:8 + netbox:v4.5.8 (~700MB total)
  # and runs initial DB migrations. Default 5m create timeout isn't enough.
  # The job's own progress_deadline is "15m" — match it here.
  timeouts {
    create = "20m"
    update = "20m"
  }
}

resource "nomad_job" "docs" {
  depends_on = [
    null_resource.nomad_vault_config,
    null_resource.docs_build,
    nomad_csi_volume_registration.docs,
  ]

  jobspec = templatefile("${path.module}/templates/docs.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false
}

# Periodic Netbox inventory sync. Pulls UniFi devices/networks into
# Netbox on a cron schedule (default every 6 hours). Replaces the
# one-shot null_resource.netbox_unifi_devices in netbox-inventory.tf
# for ongoing refresh — that resource only re-runs when its config
# triggers change, not when the actual UniFi data does.
resource "nomad_job" "netbox_sync" {
  count = var.deploy_netbox && var.unifi_address != "" ? 1 : 0
  depends_on = [
    nomad_job.netbox,
    vault_policy.netbox_sync,
    vault_jwt_auth_backend_role.netbox_sync,
    vault_kv_secret_v2.unifi,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/netbox-sync.nomad.hcl.tpl", {
    sync_cron     = var.netbox_sync_cron
    sync_timezone = var.netbox_sync_timezone
    site_slug     = replace(lower(var.dns_postfix), ".", "-")
  })
  detach = false
}

resource "nomad_job" "tailscale" {
  count = var.deploy_tailscale ? 1 : 0
  depends_on = [
    vault_policy.tailscale,
    vault_jwt_auth_backend_role.tailscale,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/tailscale.nomad.hcl.tpl", {
    tailscale_subnet = coalesce(var.tailscale_advertise_routes, var.network_cidr)
  })
  detach = false
}

# Profile-folder reconciler — pre-creates per-user directories + ACLs on
# every opted-in NAS so AD users can land directly into their roaming
# profile share (no manual TrueNAS UI work per user). Deploys only when
# at least one nas_servers entry has provides_profiles=true.
resource "nomad_job" "profile_reconciler" {
  count = var.deploy_samba_ad && length(local.profile_nases) > 0 ? 1 : 0
  depends_on = [
    vault_policy.profile_reconciler,
    vault_jwt_auth_backend_role.profile_reconciler,
    null_resource.nas_profile_share,
    null_resource.nomad_vault_config,
    null_resource.ad_groups,
  ]

  jobspec = templatefile("${path.module}/templates/profile-reconciler.nomad.hcl.tpl", {
    cron_schedule = var.profile_reconciler_cron
    time_zone     = var.profile_reconciler_timezone
    profile_group = var.profile_group
    profile_nases = [for nas in var.nas_servers : {
      name             = nas.name
      address          = nas.address
      profile_dataset  = nas.profile_dataset
      profile_ad_group = nas.profile_ad_group
    } if nas.provides_profiles && nas.type == "truenas" && nas.profile_dataset != ""]
  })
  detach = false
}


# =============================================================================
# CSI plugin (csi-driver-nfs) — controller + node jobs
# =============================================================================
# Phase 1 of the GlusterFS → NAS-backed-CSI migration. Mounts the per-service
# NFS shares created by null_resource.nas_share into Nomad allocations.
# See plans/serene-brewing-cray.md for migration arc.

resource "nomad_job" "csi_controller" {
  count      = var.deploy_csi ? 1 : 0
  depends_on = [null_resource.nas_share]

  jobspec = templatefile("${path.module}/templates/csi-controller.nomad.hcl.tpl", {
    csi_driver_nfs_version = var.csi_driver_nfs_version
  })
  detach = false
}

resource "nomad_job" "csi_node" {
  count      = var.deploy_csi ? 1 : 0
  depends_on = [nomad_job.csi_controller]

  jobspec = templatefile("${path.module}/templates/csi-node.nomad.hcl.tpl", {
    csi_driver_nfs_version = var.csi_driver_nfs_version
  })
  detach = false
}
