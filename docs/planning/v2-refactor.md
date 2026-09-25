# v2 Refactor (`refactor/v2`)

Status doc for the "new version" of proxmox-lab — the `refactor/v2` branch.

## TL;DR

`refactor/v2` is the active development line and the intended successor to `main`.
It is an **IaC-first rewrite**: work that used to live in `lib/*.sh` bash moved into
**Terraform / Packer / Nomad**, and the storage layer moved from **GlusterFS** to
**CSI + NFS** on TrueNAS. It is a net **simplification** — more code removed than added.

| Metric | Value |
|--------|-------|
| Commits ahead of `main` | **252** (2026-04-10 → 2026-09-02) |
| Diff vs `main` | 209 files, **+17,634 / −22,195** (net **−4,561** lines) |
| `lib/` (bash) change | +2,395 / **−8,427** (~6k lines of bash removed) |
| Merge state | **Not yet merged to `main`** (`main` @ `5fbb9c8`, `release/v1` == main) |

> Point-in-time source-control status (unpushed commits, stashes, deployed-vs-repo
> gaps on the lab admin host) is tracked lab-side in
> `iotvf-lab/project-updates/2026-09-25-refactor-v2-status.md`, not here — that state
> changes as the branch is pushed/merged.

## What changed (major workstreams)

The refactor was executed as several **phased** arcs (commit subjects tagged "Phase N"):

1. **Storage: GlusterFS → CSI + NFS** (May 27–28, Phases 0–3)
   - Per-service TrueNAS **datasets + NFS exports**; deploy `csi-driver-nfs` plugin;
     Nomad jobs mount CSI volumes (`multi-node-multi-writer`).
   - **Stripped GlusterFS** install + gluster-write code out of `vm-nomad` and the
     services layer. (GlusterFS is now decommissioned on the live lab; Vault uses Raft.)

2. **Vault HA** (May 4, Phases 1–4)
   - Single Vault → **system job + integrated Raft** cluster; listener cert covers every
     Nomad node; multi-node unseal flow; **DNS-based Nomad WIF** address.

3. **Roaming profiles** (May 18, Phases 1–5)
   - Extended `nas_servers` schema; **auto-create** TrueNAS dataset/share/ACL;
     `profile-reconciler` periodic Nomad job; `d16` manual reconcile trigger.

4. **NAS classification + ACLs** (June, Phases 4–5)
   - `validateNASStorage` preflight gate in bootstrap; `nas-acls` + dataset/group model
     (ties into the ISO-27001 four-tier data classification).

5. **Bash → IaC / setup flow** (throughout)
   - **Rewrote `setup.sh` around a bootstrap flow**; removed sed-based config mutation;
     replaced the bash YAML parser with **python3**; SSH-based agent install → **cloud-init
     vendor snippet**; deleted dead bash deploy scripts, old Nomad job files, orphaned docs.

6. **Services added / reworked**
   - `unifi-dns` (Nomad job + Vault/OIDC/DNS wiring); **netbox** with a **periodic UniFi
     sync job** (replaced a one-shot scrape); **Kasm SAML → LDAP outpost** for credential
     passthrough; Uptime Kuma → 2.x; Authentik application/OIDC wiring.

7. **Networking / PKI / hardening**
   - Nomad VMs → **static IPs**; PKI chain **EC → RSA** (root/intermediate 4096, leaf 2048);
     apt sources → **HTTPS** (fixes deploys on networks blocking port 80); Layer 2 split
     around the DNS LXC deploy to break a circular dependency.

## Path to `main`

1. **Push** `refactor/v2` to origin (keep the branch backed up off the admin host).
2. **Validate** both Terraform roots before the PR:
   ```bash
   docker run --rm -v "$(pwd):/repo" -w /repo/terraform          hashicorp/terraform:1.14 validate
   docker run --rm -v "$(pwd):/repo" -w /repo/terraform/services hashicorp/terraform:1.14 validate
   ```
   (The compose `terraform` service only mounts `/terraform`; validating
   `terraform/services` needs the whole-repo mount above because policy files are
   referenced via `../../nomad/`.)
3. **Open the PR:** `https://github.com/jknyght9/proxmox-lab/compare/main...refactor/v2`
   (or `gh pr create` once `gh auth login` is done). 252 commits is a large single PR —
   decide whether to review-and-merge or **fast-forward `main` to `refactor/v2`** at a cut
   point and tag it (e.g. `v2.0.0`) since `release/v1` already pins the v1 line.

## Outstanding before merge

- **Root `WORKTREE.*.md`** working-note files are tracked and effectively cruft — remove or
  gitignore before the PR.
- Prune merged local branches (`feature/uptime-kuma-refresh` is already on `main`, etc.).
- Confirm `bootstrap.yml.example` no longer advertises stale guidance (e.g. Synology
  `api_key` note) picked up during the storage migration.
- Update this doc's status line and the README when `main` is cut over.
