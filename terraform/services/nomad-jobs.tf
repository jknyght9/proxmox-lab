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

resource "nomad_job" "forgejo" {
  count = var.deploy_forgejo ? 1 : 0
  depends_on = [
    vault_policy.forgejo,
    vault_jwt_auth_backend_role.forgejo,
    vault_kv_secret_v2.forgejo,
    null_resource.nomad_vault_config,
    nomad_csi_volume_registration.forgejo_pg,
    nomad_csi_volume_registration.forgejo_data,
  ]

  jobspec = templatefile("${path.module}/templates/forgejo.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false

  # First run pulls postgres:17 + the forgejo image (~400MB) and runs the
  # initial DB migrations. Default 5m create timeout is too tight; match the
  # job's own 15m progress_deadline.
  timeouts {
    create = "20m"
    update = "20m"
  }
}

resource "nomad_job" "kaneo" {
  count = var.deploy_kaneo ? 1 : 0
  depends_on = [
    vault_policy.kaneo,
    vault_jwt_auth_backend_role.kaneo,
    vault_kv_secret_v2.kaneo,
    null_resource.nomad_vault_config,
    nomad_csi_volume_registration.kaneo_pg,
  ]

  jobspec = templatefile("${path.module}/templates/kaneo.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false

  # First run pulls postgres:16-alpine + the kaneo image and runs the initial
  # DB migrations. Default 5m create timeout is too tight; match the job's own
  # 15m progress_deadline.
  timeouts {
    create = "20m"
    update = "20m"
  }
}

# Forgejo Actions runner registration-token mint.
#
# After the forgejo job is up, mint an INSTANCE-LEVEL registration token from
# the live Forgejo API and write it to Vault at secret/forgejo-runner, where
# the runner job reads it (via its Vault template) and registers once.
#
# Mirrors the authentik_apps / nas_share remote-exec pattern: SSH to nomad01
# (which can reach git.<postfix> over the internal CA and the Vault API), then
# curl both APIs. The bearer is the Forgejo automation token at
# secret/forgejo.automation_token — created in the manual Phase 2b step
# (docs/services/forgejo.md). If that token is absent, this logs a clear
# message and leaves the placeholder empty (the runner job then refuses to
# register with an actionable error) rather than failing the whole apply.
resource "null_resource" "forgejo_runner_token" {
  count = var.deploy_forgejo_runner ? 1 : 0
  depends_on = [
    nomad_job.forgejo,
    vault_kv_secret_v2.forgejo_runner,
  ]

  triggers = {
    # Re-mint on every apply. The instance registration token is stable until
    # explicitly reset in Forgejo, so re-fetching simply re-writes the same
    # value — cheap and keeps secret/forgejo-runner current.
    always = timestamp()
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
      FORGEJO_URL="https://git.${var.dns_postfix}"
      VAULT_ADDR="${var.vault_address}"
      VAULT_TOKEN="${var.vault_token}"

      echo '[+] Reading Forgejo automation token from secret/forgejo...'
      AUTO_TOKEN=$(curl -sk -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/secret/data/forgejo" \
        | jq -r '.data.data.automation_token // ""')

      if [ -z "$AUTO_TOKEN" ] || [ "$AUTO_TOKEN" = "null" ]; then
        echo "[!] secret/forgejo has no 'automation_token' key."
        echo "[!] Create the Forgejo admin user + an automation access token"
        echo "[!] (Phase 2b, see docs/services/forgejo.md), store it at"
        echo "[!] secret/forgejo automation_token=<tok>, then re-apply."
        echo "[!] Leaving secret/forgejo-runner.registration_token empty for now."
        exit 0
      fi

      echo '[+] Minting instance-level runner registration token...'
      # Non-deprecated path in Forgejo 16.x (verified in the live swagger).
      REG_TOKEN=$(curl -sk -H "Authorization: token $AUTO_TOKEN" \
        "$FORGEJO_URL/api/v1/admin/actions/runners/registration-token" \
        | jq -r '.token // ""')

      if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
        echo "[!] Registration-token mint returned nothing — is the automation"
        echo "[!] token an ADMIN token? Falling back to the deprecated alias..."
        REG_TOKEN=$(curl -sk -H "Authorization: token $AUTO_TOKEN" \
          "$FORGEJO_URL/api/v1/admin/runners/registration-token" \
          | jq -r '.token // ""')
      fi

      if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
        echo "[!] Could not mint a registration token. Check the automation"
        echo "[!] token's admin scope. Leaving secret/forgejo-runner empty."
        exit 0
      fi

      echo '[+] Writing registration token to secret/forgejo-runner...'
      curl -sk -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H "Content-Type: application/json" \
        "$VAULT_ADDR/v1/secret/data/forgejo-runner" \
        -d "{\"data\":{\"registration_token\":\"$REG_TOKEN\"}}" > /dev/null
      echo '[+] Runner registration token stored at secret/forgejo-runner'
      EOT
    ]
  }
}

resource "nomad_job" "forgejo_runner" {
  count = var.deploy_forgejo_runner ? 1 : 0
  depends_on = [
    vault_policy.forgejo_runner,
    vault_jwt_auth_backend_role.forgejo_runner,
    vault_kv_secret_v2.forgejo_runner,
    null_resource.nomad_vault_config,
    null_resource.forgejo_runner_token,
    nomad_csi_volume_registration.forgejo_runner_data,
  ]

  jobspec = templatefile("${path.module}/templates/forgejo-runner.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false

  # First run pulls docker:28-dind + the runner image and registers against
  # Forgejo. Default 5m create timeout is too tight; match the job's own 15m
  # progress_deadline.
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

# unifi-dns — UniFi local-DNS management app (Postgres + FastAPI + nginx SPA).
# Backend/frontend images must be published to GHCR first (they build from
# source; Nomad only pulls). See docs/unifi-dns-integration.md.
resource "nomad_job" "unifi_dns" {
  count = var.deploy_unifi_dns ? 1 : 0
  depends_on = [
    vault_policy.unifi_dns,
    vault_jwt_auth_backend_role.unifi_dns,
    vault_kv_secret_v2.unifi_dns,
    vault_kv_secret_v2.unifi_dns_oidc,
    vault_kv_secret_v2.unifi,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/unifi-dns.nomad.hcl.tpl", {
    dns_postfix              = var.dns_postfix
    unifi_address            = var.unifi_address
    unifi_site               = var.unifi_site
    unifi_dns_backend_image  = var.unifi_dns_backend_image
    unifi_dns_frontend_image = var.unifi_dns_frontend_image
  })
  detach = false

  # First run pulls postgres:18 + the two GHCR images and runs alembic
  # migrations on backend start. Default 5m create timeout is too tight.
  timeouts {
    create = "20m"
    update = "20m"
  }
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
