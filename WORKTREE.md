# WORKTREE.md — feature/uptime-kuma-refresh

> **This file is a contract for AI assistants operating in this worktree.**
> **Read and comply with ALL sections before performing any work.**

## Branch
`feature/uptime-kuma-refresh`

## Purpose
Move the Uptime Kuma Nomad job from `louislam/uptime-kuma:1` to
`louislam/uptime-kuma:2`. Rely on the boot-time mount sequencing and
per-job `wait-for-gluster` guard (shipped on `fix/gluster-mount-race`) to
keep its state across reboots. Admin provisioning and auth-disable are
one-time manual steps through the UI — the 1.x image has no env-var path
to do them, and 2.x is no better; since persistence is now trustworthy,
setting them up once is sufficient.

## Environments
- **jdclabs** — development / testing lab.
- **iotvf.lab** — production network at a different physical facility.

## Scope

### In Scope (may be modified)
- `nomad/jobs/uptime-kuma.nomad.hcl` — the job spec.
- `lib/deploy/nomadJob/deployUptimeKuma.sh` — deploy helper, if the 2.x
  image needs a new storage directory or a pre-deploy step.
- `.claude/CLAUDE.md` — the Uptime Kuma section only, to reflect the
  version bump and document the one-time UI setup.
- `WORKTREE.md` — this contract.

### Out of Scope (MUST NOT be modified on this branch)
- Any other Nomad job file.
- `terraform/`, `packer/`, `lib/proxmox/**`, `lib/deploy/deploy*Services.sh`.
- `crypto/**` — never read file contents.
- `docs/`, `mkdocs.yml`, `mkdocs/` — owned by the docs branch.

## Architectural Constraints
- **No admin/auth automation.** The first-time setup wizard is a UI
  flow; the disable-auth toggle is a post-setup UI action. We accept
  that these are one-time manual steps. Trusting persistence is the
  contract.
- **Trust the gluster mount-race fix.** The job already inherits the
  `wait-for-gluster` prestart from main. Don't reinvent the guard.
- **Image tag stability.** Pin to the lightest-touch 2.x tag that gives
  us reasonable patch uptake. If `louislam/uptime-kuma:2` resolves to
  an unreleased beta on pull, downgrade to a specific tag and note why.
- **DB-backend uncertainty.** Uptime Kuma 2.x may require an external DB
  (MariaDB has been discussed upstream). If the first deploy of `:2`
  shows the container needs a DB sidecar, adjust the job to add one and
  update this contract — do not silently ship a half-working config.
- **Both environments.** No hard-coded realms, IPs, or paths.

## Forbidden Actions
- Do NOT modify files outside the "In Scope" list.
- Do NOT read `crypto/` contents.
- Do NOT wipe `/srv/gluster/nomad-data/uptime-kuma/` without explicit
  user instruction — even though data was already lost during the
  mount-race incident, fresh state from any successful setup must be
  preserved going forward.
- Do NOT run destructive git operations.

## Success Criteria
- [ ] `nomad/jobs/uptime-kuma.nomad.hcl` uses a `:2`-series image.
- [ ] Job deploys cleanly on Nomad; `wait-for-gluster` prestart passes;
      main task is running.
- [ ] Web UI reachable through Traefik at `status.<dns_postfix>`.
- [ ] Operator completes first-time setup and flips Settings → Security
      → Disable Auth.
- [ ] After a cold reboot of the host node, Uptime Kuma comes back with
      monitors intact and auth still disabled.
- [ ] CLAUDE.md reflects the new version and documents the one-time
      setup steps.

## Key Context

**Prior incident (2026-04-16, iotvf.lab):** reboot without the mount fix
caused Uptime Kuma to bind an empty pre-mount local directory and
prompt for a fresh admin account. All prior monitors and config were
lost. The gluster-mount-race branch shipped host-level sequencing plus a
per-job sentinel check that would have prevented this.

**Source of truth files:**
- `nomad/jobs/uptime-kuma.nomad.hcl`
- `lib/deploy/nomadJob/deployUptimeKuma.sh`
- `.claude/CLAUDE.md` — Uptime Kuma configuration section.

**Known unknowns:**
- Whether `:2` is a stable tag at pull time, beta, or moving target.
- Whether Uptime Kuma 2.x requires an external DB sidecar.
- Upstream config-format changes between 1.x and 2.x (monitor schema,
  notification providers).

## Contract Version
Created: 2026-04-17
Supersedes on this branch: `WORKTREE.gluster-mount-race.md` (preserved
unchanged for reference).
