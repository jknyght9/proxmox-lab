# WORKTREE.md — refactor/v2

> **This file is a contract for AI assistants operating in this worktree.**
> **Read and comply with ALL sections before performing any work.**

## Branch
`refactor/v2`

## Purpose
Release candidate for proxmox-lab v2. Consolidates two parallel refactor
branches (`refactor/phase-1-bootstrap-packer` and
`refactor/phase-2-core-infra`) with the three v1 feature/fix merges on top
(`feature/ad-join`, `fix/gluster-mount-race`, `feature/uptime-kuma-refresh`).
When this branch is validated end-to-end on both environments, it replaces
`main`; `main` then tags `v2.0.0` and the old v1 line continues to live on
`release/v1` for long-tail support.

The refactor's overall direction — which this branch must preserve — is to
move deployment work out of ad-hoc bash scripts and into Terraform, Packer,
and Nomad job definitions. Bash is reserved for interactive / REST-API
orchestration (TrueNAS join, Vault AppRole creation, one-shot diagnostics).

## Environments
Both environments must work unchanged:

- **jdclabs** — development / testing lab. Validate here first.
- **iotvf.lab** — production, separate physical facility. Do not apply
  refactor/v2 against iotvf.lab until jdclabs passes end-to-end.

## Scope

### In Scope (the entire codebase, constrained by intent)
Because this is the refactor, nearly every path is in-scope. The constraint
is not path-based — it is intent-based: changes must advance toward the
refactor's goals, not re-introduce patterns the refactor is removing.

- `terraform/` — any module may be modified. New modules allowed.
- `packer/` — base, docker, and nomad templates; provisioners.
- `nomad/jobs/` and `nomad/vault-policies/` — job specs and Vault policy
  files.
- `lib/` — bash helpers, including the bootstrap flow.
- `setup.sh` — interactive menu and argument parsing.
- `.claude/CLAUDE.md` — documentation of current v2 architecture.
- `WORKTREE.md` — this contract.
- `bootstrap.yml.example`, `env.example`, `compose.yml` — supporting config.

### Out of Scope (MUST NOT be modified on this branch)
- `docs/`, `mkdocs.yml`, `mkdocs/` — owned by the docs branch.
- `crypto/**` — never read file contents.
- `terraform/**/terraform.tfstate` and any `*.backup` state files.
- Historical WORKTREE contracts (`WORKTREE.ad-join.md`,
  `WORKTREE.gluster-mount-race.md`, `WORKTREE.new-documentation.md`,
  `WORKTREE.uptime-kuma.md`) — these are reference snapshots of prior
  branches. Do not edit. Delete only as part of a conscious cleanup at
  the end of the refactor.
- `release/v1` branch state — this is maintenance for v1; it does not
  receive refactor work and we do not port back into it from here.

## Architectural Constraints
- **IaC-first.** When a change could live in either bash or
  Terraform/Packer/Nomad, choose IaC. The refactor deliberately deleted
  `lib/deploy/vm/fixGlusterMountOrdering.sh` because
  `terraform/vm-nomad/main.tf` does the equivalent work. Do not
  re-introduce bash shims for things Terraform can own.
- **No envsubst in Nomad job files.** Phase 2 migrated every job from
  shell-variable interpolation (`${DNS_SERVER}` etc.) to HCL2 +
  Vault KV lookups. New jobs must follow the same pattern.
- **Vault KV is the runtime config surface.** Secrets and
  environment-shaped config (DNS_POSTFIX, NOMAD01_IP, etc.) read at job
  dispatch time come from Vault KV paths, not from envsubst-rendered
  job text.
- **Mount-race fix must remain wired.** Every Nomad job that bind-mounts
  from `/srv/gluster/nomad-data` must carry a `wait-for-gluster`
  raw_exec prestart task that checks `mountpoint -q … && test -f
  …/.mount-sentinel`. The sentinel itself is written by
  `null_resource.gluster_mount_sentinel` in `terraform/vm-nomad/main.tf`.
  The Packer image bakes the `RequiresMountsFor` systemd drop-ins for
  `docker.service` and `nomad.service`. Cloud-init enables the
  `raw_exec` plugin. Do not regress any of these.
- **Samba AD stays on local storage.** `nomad/jobs/samba-dc.nomad.hcl`
  intentionally bind-mounts `/opt/samba-dc0{1,2}` rather than the
  GlusterFS volume — Samba AD requires POSIX ACL support that FUSE
  does not provide. Do not add a gluster-mounted path there and do not
  add a `wait-for-gluster` prestart to that job.
- **TrueNAS operations stay in bash.** `lib/deploy/configureTrueNAS.sh`
  drives the TrueNAS REST API through interactive prompts and Vault
  lookups. That is an acceptable home for orchestration bash, not a
  candidate for Terraform-ification in this branch.
- **Both environments, no hardcoding.** No realm, IP, DNS domain, or
  hostname from jdclabs or iotvf.lab may appear in repo code.

## Forbidden Actions
- Do NOT modify files under the "Out of Scope" list without asking first.
- Do NOT read `crypto/` file contents.
- Do NOT reference `terraform.tfstate` or `*.backup` files.
- Do NOT run destructive git operations (force push, reset --hard,
  branch deletion) without explicit instruction.
- Do NOT merge `refactor/v2` into `main` without user approval. The
  replacement happens as a single deliberate cutover, not as an
  incremental merge.

## Success Criteria
- [ ] `./setup.sh` on a clean Proxmox cluster drives a full v2 deploy
      without manual intervention between steps (outside genuinely
      interactive prompts like TrueNAS API key entry).
- [ ] `terraform apply` on `terraform/vm-nomad/` brings up the
      GlusterFS volume with hardened fstab options and writes the
      `.mount-sentinel` marker.
- [ ] Cold reboot of any Nomad node leaves the cluster in a recoverable
      state — mount up before Docker/Nomad; `wait-for-gluster` prestart
      passes on every gluster-backed job.
- [ ] All seven gluster-backed Nomad jobs pass `nomad job validate`.
- [ ] TrueNAS AD join (`d10`/`d11`) works against TrueNAS SCALE 25.10
      with hostname-keyed config in `cluster-info.json` and per-host
      Vault paths at `secret/truenas/<name>`.
- [ ] Uptime Kuma 2.x deploys, completes first-time setup, and
      persists across an alloc restart.
- [ ] Validated end-to-end on jdclabs.
- [ ] Validated against iotvf.lab (after jdclabs passes).
- [ ] `WORKTREE.md` is current (this file); stale historical contracts
      either deleted or retained with a clear note.

## Key Context

**Consolidation history:**
- `v1.0.0` tag — snapshot of main at 5fbb9c8, first feature/fix triad
  merged on top of `refactor/vault-ca` (which is already in main).
- `refactor/v2` branched from phase-1 tip (`0fd90c0`).
- `bdfae5d` — phase-2 merged in; clean auto-merge.
- `96a1828` — `v1.0.0` merged in; three real conflicts
  (`.gitignore`, `setup.sh`, `lib/deploy/vm/deployNomad.sh`) resolved.
- `fixGlusterMountOrdering.sh` deleted; mount-race hardening ported
  into `terraform/vm-nomad/main.tf`.

**Dev menu on refactor/v2:**
```
d1  Build DNS records              d7  Deploy Kasm only
d2  Rebuild Packer templates       d8  Deploy Tailscale
d3  Regenerate CA certificates     d9  Configure Authentik AD Sync
d4  Update root certificates       d10 Join TrueNAS to AD
d5  Reset API credentials          d11 Join TrueNAS to AD + profile share
d6  Deploy Nomad only              d12 Create domain-join AppRole
```
No b-series (refactor absorbed beta items into main numbered options).

**Preserved historical contracts (do not edit):**
- `WORKTREE.ad-join.md` — feature/ad-join (multi-NAS TrueNAS).
- `WORKTREE.gluster-mount-race.md` — boot-time mount sequencing.
- `WORKTREE.uptime-kuma.md` — Uptime Kuma 2.x bump.
- `WORKTREE.new-documentation.md` — original docs-site rewrite contract.

## Dependencies & Related Branches
- **Upstream of:** `main` (once validation passes, `refactor/v2` is what
  `main` will fast-forward or hard-reset to for the v2 cutover).
- **Alongside:** `release/v1` — maintenance line for v1.0.0. Fixes to
  `release/v1` are not auto-ported into `refactor/v2`; if a v1 fix is
  also needed in v2, cherry-pick explicitly.
- **Inputs:** `refactor/phase-1-bootstrap-packer`,
  `refactor/phase-2-core-infra` — fully absorbed by this branch; treat
  as closed once v2 ships.

## Contract Version
Created: 2026-04-18
Replaces: `WORKTREE.uptime-kuma.md` (preserved for reference).
