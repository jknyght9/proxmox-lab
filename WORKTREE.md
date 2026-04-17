# WORKTREE.md — feature/ad-join

> **This file is a contract for AI assistants operating in this worktree.**
> **Read and comply with ALL sections before performing any work.**
> **Violations of "Out of Scope" or "Forbidden Actions" are hard failures.**

## Branch
`feature/ad-join`

## Purpose
Extend the proxmox-lab project so additional systems can be joined to the Samba AD
domain deployed by the project. First target was TrueNAS SCALE; the scope now
includes supporting **multiple** TrueNAS servers (and, longer term, other AD-joined
clients) with per-host credentials stored in Vault and tracked in
`cluster-info.json`.

## Environments
Work on this branch must function in both environments the user operates:

- **jdclabs** — development / testing lab.
- **iotvf.lab** — production network at a different physical facility.

Both environments share this codebase; per-environment state lives in
`cluster-info.json`. AD-join plumbing must not hard-code either environment's
realm, IPs, or hostnames.

## Scope

### In Scope (may be modified)
- `lib/deploy/configureTrueNAS.sh` — TrueNAS REST-API join flow.
- `lib/deploy/nomadJob/deploySambaAD.sh` — only AD-side changes needed for
  joins (e.g., the `domain-join-svc` least-privilege service account, group
  membership, OU layout for computer accounts).
- `nomad/vault-policies/domain-join.hcl` and any new policies added to support
  per-host AD-join credentials.
- `setup.sh` — only the menu entries and dispatch for AD-join options
  (`b1` Samba AD when related, `b6`/`b7` TrueNAS join, `d10` Vault AppRole).
- New `lib/deploy/**.sh` files when needed to support AD joins for additional
  client types (e.g., a future `configureWindowsClient.sh`).
- `cluster-info.json` **schema** (the shape of AD-related keys: `ad_config`,
  `truenas`, any future per-client sections). Content in a deployed
  `cluster-info.json` is owned by the user and should not be edited in place —
  only the schema the code reads/writes.
- `WORKTREE.md` — this contract.

### Out of Scope (MUST NOT be modified on this branch)
- `terraform/**` — all modules and state.
- `packer/**` — all templates.
- `nomad/jobs/**` except `samba-dc.nomad.hcl` when a change is unavoidable
  (coordinate with the user first).
- `lib/proxmox/**` — cluster, networking, and host-setup scripts.
- `lib/deploy/deployAllServices.sh`, `deployCriticalServices.sh`,
  `rollbackDeployment.sh`, `purgeDeployment.sh` — unless an AD-join change
  requires integration there; if so, ask the user first.
- `lib/ca/**`, `lib/deploy/configureVaultWIF.sh`,
  `lib/deploy/configureNomadVaultIntegration.sh` — Vault PKI/WIF layer.
- `docs/`, `mkdocs.yml`, `mkdocs/` — owned by the docs branch.
- `crypto/**` — never read file contents; never reproduce keys/tokens.
- `terraform.tfstate` and any `*.backup` state files.
- `compose.yml`, `.claude/CLAUDE.md` — read-only reference.

## Architectural Constraints
- **Credentials live in Vault, not on disk.** AD join passwords, TrueNAS API
  keys, and any per-host secrets must be stored in Vault. `crypto/` is
  reserved for Vault bootstrap (`vault-credentials.json`) and SSH keys.
- **Per-host Vault paths.** For any client-specific credential, use a
  hostname-keyed path — e.g., `secret/truenas/<hostname>` — not a shared
  singleton path.
- **Cluster-info schema is a map.** Client-tracking entries in
  `cluster-info.json` must be maps keyed by normalized hostname (lowercase,
  first label only), not singletons or arrays. Current shape:
  ```json
  "truenas": {
    "<hostname>": { "ip": "...", "joined_at": "..." }
  }
  ```
- **Least privilege for joins.** AD computer accounts are joined via
  `domain-join-svc`, not Administrator. The account's rights must remain
  scoped to what `net ads join` / TrueNAS needs.
- **Idempotency.** Every join flow must detect prior state (already joined,
  existing Vault entry, existing cluster-info entry) and handle it
  gracefully. Re-running a flow must not corrupt state.
- **Authoritative hostname.** When a new client is added, discover its real
  hostname via its own API (not a user-typed alias) and use that as the key.
  User-typed aliases create drift when the client is later renamed or
  reconfigured.
- **Backwards-compatible migration.** Any schema change must ship with an
  idempotent migration helper that runs at the top of the affected flow and
  upgrades old state in place.
- **REST API only for TrueNAS.** No SSH + midclt. This was rewritten in
  commit `0c9050d`; do not regress.

## Forbidden Actions
- Do NOT modify files outside the "In Scope" list without asking first.
- Do NOT read file contents under `crypto/`. Abstract references are fine.
- Do NOT read or reference `terraform/terraform.tfstate` or any `.backup`.
- Do NOT store secrets (API keys, join passwords, tokens) anywhere except
  Vault.
- Do NOT join clients using Administrator credentials — always use
  `domain-join-svc`.
- Do NOT use SSH + midclt against TrueNAS; the REST API is the supported
  path.
- Do NOT invent IP addresses, realms, hostnames, or paths not grounded in
  the current codebase or the user's environment.
- Do NOT run destructive git operations (force push, hard reset, branch
  deletion) without an explicit instruction on this branch.

## Shipped on the Branch
Commits on `feature/ad-join` so far (newest first):

- `a45cf10` Use system hostname as NetBIOS name when joining AD.
- `aa076c7` Fix AD re-join: clear Kerberos principal when leaving domain.
- `ecd6d9b` Split TrueNAS AD join into two menu options (`b6` join only,
  `b7` join + profile share).
- `bdfab52` Fix TrueNAS AD join: clear all nameservers, track job ID.
- `0c9050d` Rewrite TrueNAS script to use REST API instead of SSH + midclt.
- `8361e71` Fix TrueNAS script aborting on midclt failures under `set -e`.
- `ada5955` Add `d10` menu option to create domain-join AppRole standalone.
- `bd17967` Update `.gitignore`.
- `dea666a` Add Vault AppRole for domain join and TrueNAS AD integration.
- `0d92380` Add least-privilege `domain-join-svc` account for AD machine
  joins.

Verified against `iotvf.lab`:
- Samba AD deployed on Nomad (DC01, DC02).
- `domain-join-svc` provisioned with minimal rights.
- TrueNAS SCALE (10.10.0.120) joined to `IOTVF.LAB` using
  `domain-join-svc`, API key stored in Vault at `secret/truenas`.
- User profile dataset and SMB share configured.

## In Flight
Moving TrueNAS tracking from a singleton to a hostname-keyed map so multiple
NASes can be joined:

- `cluster-info.json`: `.truenas = { "<hostname>": { ip, joined_at } }`.
- Vault: `secret/truenas/<hostname>` replaces `secret/truenas`.
- `configureTrueNAS.sh`: adds `migrateTrueNASConfig` (idempotent legacy
  converter), `selectOrAddTrueNAS` (picker), `fetchTrueNASHostname`,
  `normalizeTrueNASName`, and splits `getTrueNASAPIKey` into load + persist
  halves.

## Success Criteria (current in-flight scope)
- [ ] `configureTrueNAS.sh` treats `.truenas` as a map keyed by normalized
      hostname.
- [ ] TrueNAS API keys are stored at `secret/truenas/<hostname>`.
- [ ] Running `b6`/`b7` on a cluster with the legacy singleton format
      migrates state in place without user intervention and does not
      require re-entering the API key.
- [ ] Re-running `b6`/`b7` after migration shows a picker that lists the
      already-joined NAS and offers "add new".
- [ ] A second TrueNAS can be joined on the same cluster without clobbering
      the first entry's cluster-info or Vault secret.
- [ ] Flow works unchanged on `jdclabs` and `iotvf.lab` — no hard-coded
      realms, IPs, or hostnames.

## Key Context

**Source of truth files (read these, do not guess):**
- `lib/deploy/configureTrueNAS.sh` — TrueNAS REST-API join flow.
- `lib/deploy/nomadJob/deploySambaAD.sh` — Samba AD deploy, including
  `domain-join-svc`.
- `nomad/vault-policies/domain-join.hcl` — Vault policy for machine joins.
- `setup.sh` — menu dispatch for `b1`/`b6`/`b7`/`d10`.
- `lib/util.sh` — `info`, `doing`, `success`, `warn`, `error`, `question`,
  `header`, plus `sshRun`, `sshScript`, `scpTo`.
- `cluster-info.json` — current cluster topology + AD config.
- `crypto/vault-credentials.json` — Vault address + root token (referenced
  by path only, never inlined).

**Critical facts:**
- AD realm / domain are read from `.ad_config.realm` and `.ad_config.domain`
  in `cluster-info.json`.
- The TrueNAS REST API returns a bare job ID for async ops like
  `/activedirectory`; the flow polls `/core/get_jobs?id=…` until
  `SUCCESS` / `FAILED`.
- All nameservers on the TrueNAS must point only at the lab's Pi-hole
  during the join — external resolvers cannot find AD SRV records.
- NetBIOS name on the joined machine is the system hostname
  (uppercased), matching what Samba AD records as the computer name.
- The `domain-join-svc` password lives in Vault at
  `secret/data/samba-ad` under `domain_join_password`.

## Contract Version
Created: 2026-04-16
Supersedes for this branch: `WORKTREE.new-documentation.md` (preserved for
the docs branch's contract).
