# WORKTREE.md — fix/gluster-mount-race

> **This file is a contract for AI assistants operating in this worktree.**
> **Read and comply with ALL sections before performing any work.**
> **Violations of "Out of Scope" or "Forbidden Actions" are hard failures.**

## Branch
`fix/gluster-mount-race`

## Purpose
After a Nomad-node reboot, `/srv/gluster/nomad-data` is frequently not
mounted by the time Docker and Nomad begin starting allocations. Jobs with
bind mounts off the GlusterFS volume (Vault, Traefik, Authentik,
Uptime-Kuma, Samba DCs, Tailscale, LAM, backups) bind to empty local
directories instead, leading to silent data loss or stale in-memory state
(e.g., Traefik serving its default self-signed cert; Uptime-Kuma asking to
reprovision the admin user).

Scope for this branch:

1. **Fix the mount sequencing** so `/srv/gluster/nomad-data` is mounted
   before Docker and Nomad start, on every boot.
2. **Audit and harden every Nomad job** that bind-mounts off the volume
   so it refuses to start (or self-repairs) when the mount is missing or
   empty.
3. **Document** the guard so future jobs follow the pattern.

## Environments
The fix must work in both environments the user operates:

- **jdclabs** — development / testing lab.
- **iotvf.lab** — production network at a different physical facility.

## Scope

### In Scope (may be modified)
- `packer/build_nomad.pkr.hcl` and any scripts it invokes — to install the
  systemd dependency wiring into the Nomad VM image.
- `packer/scripts/` helpers that touch mount / systemd config, if any.
- `terraform/vm-nomad/cloudinit/` templates — if cloud-init is the right
  layer for the drop-in.
- `nomad/jobs/*.hcl` — every job with a GlusterFS bind mount gets a
  pre-start guard (prestart task or script check).
- `lib/deploy/nomadJob/deploy*.sh` — deploy helpers that materialize job
  files if guards need to be rendered from templates.
- `CLAUDE.md` — document the mount-race fix and the new guard pattern
  for future jobs.
- `WORKTREE.md` — this contract.

### Out of Scope (MUST NOT be modified on this branch)
- AD-join flow (`lib/deploy/configureTrueNAS.sh`,
  `lib/deploy/nomadJob/deploySambaAD.sh` beyond any mount-guard change,
  `nomad/vault-policies/domain-join.hcl`, menu entries `b6`/`b7`/`d10`).
  That work shipped on `feature/ad-join` and is closed.
- `terraform/` modules other than `vm-nomad`.
- `lib/proxmox/**` except the minimum needed to invoke Packer with updated
  templates.
- `lib/deploy/deployAllServices.sh`, `deployCriticalServices.sh`,
  `rollbackDeployment.sh`, `purgeDeployment.sh` — unless an unavoidable
  integration point turns up; ask first.
- `docs/`, `mkdocs.yml`, `mkdocs/` — owned by the docs branch.
- `crypto/**` — never read file contents.
- `terraform.tfstate` and any `*.backup` state files.

## Architectural Constraints
- **Mount-first, services-second.** The gluster client mount must come up
  before `docker.service` and `nomad.service` start. No job should be
  able to bind-mount a pre-mount path by accident.
- **No reliance on eventual consistency.** Do not paper over the race
  with retry loops inside containers; fix the ordering at the host.
- **Jobs must be self-defending.** Every Nomad job with a gluster bind
  mount gets a pre-start check that verifies the mount is present and
  populated (a sentinel file or known directory). A failed check causes
  the alloc to fail fast rather than create empty state.
- **Idempotent, repeatable.** Re-running Packer / redeploying Nomad jobs
  must not break existing clusters. The fix should work on a fresh build
  and on already-deployed nodes (via a one-shot push).
- **Both environments.** Nothing hard-coded to jdclabs or iotvf.lab.

## Forbidden Actions
- Do NOT modify files outside the "In Scope" list without asking first.
- Do NOT read file contents under `crypto/`.
- Do NOT reference `terraform.tfstate` or any `.backup` file.
- Do NOT run destructive git operations (force push, reset --hard,
  branch deletion) without an explicit instruction.
- Do NOT wipe or restart running Nomad allocations mid-debug without
  user approval — allocs are holding the only correct state for now.

## Success Criteria
- [ ] After a cold reboot of any Nomad node, `/srv/gluster/nomad-data` is
      mounted before Docker or Nomad start a single allocation.
- [ ] Verified by inspecting systemd journal: mount unit reports
      "Mounted" prior to `docker.service` and `nomad.service` entering
      `active (running)`.
- [ ] If the gluster volume is degraded or unreachable at boot, Docker
      and Nomad **do not start services with empty bind mounts** — they
      either wait, or the jobs fail fast.
- [ ] Every affected Nomad job has a pre-start guard that fails the
      alloc when the bind-mount target is missing or empty (with
      documented sentinel).
- [ ] Test: manually `umount` the volume on a single node, restart one
      affected job there — it fails; remount, restart — it succeeds.
- [ ] CLAUDE.md documents both the boot sequencing and the job guard
      pattern.
- [ ] Works on jdclabs and iotvf.lab without per-env changes.

## Key Context

**Observed symptoms (from the incident on iotvf.lab, 2026-04-16):**
- After reboot, all three nomad nodes had `glusterd` running and bricks
  online, but `/srv/gluster/nomad-data` was not a mountpoint.
- `/etc/fstab` had `localhost:/nomad-data /srv/gluster/nomad-data
  glusterfs defaults,_netdev 0 0`. `_netdev` alone did not sequence the
  mount after `glusterd.service`.
- `mount -a` succeeded immediately once run manually.
- Vault failed 22 times in a reschedule loop because its TLS cert dir
  was empty (the bind mount pointed at the local empty directory that
  was present before the gluster mount came up).
- Traefik ran with its default self-signed cert because its TLS files
  were in the same empty bind. A container restart fixed it.
- Uptime-Kuma started with an empty SQLite directory and prompted the
  admin to re-create an account — data from the gluster volume was
  inaccessible to the already-running container.

**Source of truth files (read these, don't guess):**
- `packer/build_nomad.pkr.hcl` and `packer/scripts/` — Nomad template
  build: where the gluster client config and systemd hooks live.
- `terraform/vm-nomad/cloudinit/` — per-VM cloud-init templates for the
  cluster; may be the right place for a drop-in.
- `nomad/jobs/*.hcl` — every job to audit for gluster bind mounts.
- `CLAUDE.md` — existing GlusterFS section, troubleshooting references.

**Jobs that bind-mount off `/srv/gluster/nomad-data` (guarded):**
- `vault.nomad.hcl` — `vault/`, `vault-tls/`, `certs/`.
- `traefik.nomad.hcl` — `traefik/` via Nomad `host_volume "gluster-data"`.
- `authentik.nomad.hcl` — `authentik/postgres`, `authentik/data`,
  `authentik/branding`, `certs/root_ca.crt`.
- `uptime-kuma.nomad.hcl` — `uptime-kuma/`.
- `backup.nomad.hcl` — reads `/srv/gluster/nomad-data` read-only.
- `tailscale.nomad.hcl` — `tailscale/${node.unique.name}/`.
- `lam.nomad.hcl` — `lam/config`, `lam/session`.

**Jobs on local storage (no guard needed):**
- `samba-dc.nomad.hcl` — uses `/opt/samba-dc01/`, `/opt/samba-dc02/` by
  design; Samba AD requires POSIX ACL support that GlusterFS FUSE lacks.

## Dependencies & Related Worktrees
- **Relies on:** `feature/ad-join` merged into `main` (2026-04-17).
- **Blocks:** `feature/uptime-kuma-refresh` — that branch is parked
  until this fix ships so that Uptime-Kuma persistence can be trusted
  before we change the deployment.

## Contract Version
Created: 2026-04-17
Supersedes on this branch: `WORKTREE.ad-join.md` (preserved unchanged).
