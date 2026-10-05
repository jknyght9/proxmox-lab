# Lab Management Tools — Kaneo, Forgejo, versitygw

**Status:** Planning — integration shape agreed; **no build until this doc is signed off.**
Branch: `pm-code-repo`.

Stand up three self-hosted lab-management services and a CI runner, integrated into
the existing proxmox-lab stack (Nomad, Traefik, Authentik, Vault, CSI/NFS, internal
DNS + PKI) rather than as the hand-rolled, IP-only Docker Compose the upstream build
brief assumed:

- **Kaneo** — project-management board.
- **Forgejo** — Git code hosting + Forgejo Actions.
- **versitygw** — S3-compatible object storage for **OpenTofu/Terraform state** + Packer.
- **Forgejo Actions runner** — CI executor (DinD), its own Proxmox token.

## Integration principle

The upstream brief declares Authentik, TLS, and DNS "out of scope" and deploys by hand
on IPs. **We already have all of those**, so those items are *in scope here* and the
services inherit them. The brief's "deploy by hand, outside state" rule exists for one
real reason — *the state backend cannot be managed by the state it holds* — which in our
stack collapses to a **single exception: versitygw**. Everything else is a normal Nomad
service.

| Concern | Upstream brief | Here |
|---|---|---|
| Deployment | by-hand Docker Compose | Nomad jobs (Kaneo/Forgejo/runner); versitygw = TrueNAS bootstrap |
| TLS | out of scope (HTTP) | Traefik + Vault-PKI wildcard, from day one |
| DNS | out of scope (IPs) | internal records (`git.`, `tasks.`, `s3.`) |
| SSO | out of scope | Authentik OIDC (Forgejo group→team; Kaneo email-only) |
| Secrets | `.env` + "secret store" | Vault (`secret/forgejo`, `secret/kaneo`, `secret/versitygw`, CI token) |
| State backend | bootstrap, by hand | bootstrap on TrueNAS, kept **outside** the state it holds |

## Locked decisions

1. **Domain/env:** the existing cluster + lab domain (`git.<dns_postfix>`, `tasks.<dns_postfix>`,
   `s3.<dns_postfix>`).
2. **versitygw runs on TrueNAS** (the `cluster_state` NAS) against a **local ZFS dataset** —
   native xattrs, ZFS snapshots as the state-undo, `cat`-readable state. Deployed as a
   **TrueNAS Custom App via the TrueNAS API** (our existing `nas-*.tf` pattern), with a
   documented hand-run fallback.
3. **Forgejo + Kaneo data on TrueNAS/CSI** (NFS, snapshotted). Minor git-over-NFS perf caveat
   accepted in exchange for snapshots.
4. **Runner gets its own distinct Proxmox CI token** (apply-capable), separate from the
   read-only Pulse token, stored in Vault and injected as a runner secret.
5. **Menu:** one grouped option — *"Deploy lab management tools: Kaneo, Forgejo, versitygw"*.
6. **Scope boundary:** this branch stands the platform up and leaves the `tfstate`/`packer`
   buckets **ready but unused**. Migrating proxmox-lab's own backend (local → S3, Terraform →
   OpenTofu) is a **separate follow-up** (`LAB-TEMPLATES-IAC`). proxmox-lab stays deployable
   on local state throughout.

## Service designs

### versitygw (bootstrap — the one exception)
- **Host:** TrueNAS `cluster_state` NAS, dedicated ZFS dataset (e.g. `<pool>/lab-objects`).
  Hard requirement: a **local** filesystem with xattrs + working advisory locks. **Never**
  CSI/NFS — advisory locking over NFS silently defeats the `If-None-Match` state lock.
- **Deploy:** TrueNAS Custom App (`versity/versitygw:v1.8.0`, `posix /data`, port 7070),
  provisioned via the TrueNAS API from a dedicated bootstrap step (NOT the Layer-2 services
  apply), always applied with **local** state so it never ends up inside the state it serves.
- **Buckets:** `tfstate`, `packer`.
- **Secrets:** root access/secret key → `secret/versitygw` in Vault (also the operator's store).
- **DNS/TLS:** optional Traefik front at `s3.<dns_postfix>`; the state backend itself can be
  reached directly on `:7070` (clients use `-k`/the PKI CA as elsewhere).
- **Gate (blocks everything downstream):** `tools/s3-lock-probe.sh` must exit 0 with a real
  `412` on the second conditional write. Enable ZFS snapshots on the dataset.

### Forgejo (Nomad service)
- **Job:** `templates/forgejo.nomad.hcl.tpl`, pinned per the service-job convention; Traefik
  router `git.<dns_postfix>` (+ SSH ent, e.g. `:2222`), Vault-PKI TLS.
- **Storage:** CSI/NFS volume `forgejo-data` (snapshotted). Named volume, never a bind mount.
- **Config:** `DISABLE_REGISTRATION=true`, `INSTALL_LOCK=true`, Actions enabled; distinct
  cookie/CSRF names are unnecessary once it has its own hostname (our setup gives it one).
- **SSO:** Authentik OIDC provider + app in `authentik-apps.tf`, **group→team mapping**
  (Authentik groups drive Forgejo org/team membership). Admin + automation token created by
  CLI (`forgejo admin …`), token → Vault `secret/forgejo`.
- **Repos/org:** org for the lab; repos `lab-templates`, `proxmox-lab`, `lab-services`;
  import `lab-templates` history via Forgejo migration (not a file copy).
- **Acceptance:** admin OIDC login; `/api/v1/user` returns with the token; repos exist;
  imported history present.

### Kaneo (Nomad service)
- **Job:** `templates/kaneo.nomad.hcl.tpl` (postgres + server), Traefik `tasks.<dns_postfix>`,
  Vault-PKI TLS. Image tags drop the `v` (`2.29.1`).
- **Storage:** CSI/NFS `kaneo-pg` (like the netbox pg volume).
- **Secrets:** `POSTGRES_PASSWORD`, `AUTH_SECRET` → `secret/kaneo`; `KANEO_CLIENT_URL` set to
  the real URL; `DISABLE_REGISTRATION=true` after accounts exist.
- **SSO:** Authentik OIDC (email-linked). **Membership is manual** — no group-claim mapping
  (accepted). Columns created-not-renamed (slugs are fixed at creation).
- **Acceptance:** OIDC sign-in; board renders; re-running the seed makes no duplicates.

### Forgejo Actions runner (Nomad service)
- **Job:** `templates/forgejo-runner.nomad.hcl.tpl`, **DinD** (not host socket), own
  registration token from this Forgejo, explicit labels.
- **Secrets:** a **distinct, apply-capable Proxmox token** (not the read-only Pulse token) in
  Vault, injected as a runner secret; never committed, never in a repo.
- **Isolation:** one runner per environment — never shared across environments/tenants.
- **Acceptance:** a trivial `lab-services` workflow runs green. Real pipelines belong to the
  `LAB-TEMPLATES-IAC` follow-up.

## Repo changes (what this branch adds)

Layer 2 (`terraform/services/`), mirroring the netbox/pulse pattern:
- `templates/{forgejo,kaneo,forgejo-runner}.nomad.hcl.tpl`
- `nomad-jobs.tf` → `nomad_job.{forgejo,kaneo,forgejo_runner}` gated on `deploy_*`
- `vault-secrets.tf` → `secret/forgejo`, `secret/kaneo`, `secret/versitygw`, CI token
- `vault-policies.tf` + `vault-auth.tf` → WIF roles
- `authentik-apps.tf` → OIDC provider+app for Forgejo (group→team) and Kaneo
- `dns-records.tf` → `git.`, `tasks.`, `s3.`
- `csi-volumes.tf` → `forgejo-data`, `kaneo-pg`
- `variables.tf` → `deploy_forgejo`, `deploy_kaneo`, `deploy_forgejo_runner` (+ versitygw vars)

Bootstrap + tooling + glue:
- `terraform/` (or a dedicated bootstrap path) → versitygw dataset + TrueNAS Custom App via
  the TrueNAS API, **local-state only**
- `tools/s3-lock-probe.sh` → the state-lock gate (committed)
- `lib/deploy/nomadJob/initVault.sh` → **preserve** the new `deploy_*` flags across tfvars
  regen (the known drop-on-regen bug class)
- `setup.sh` → the grouped menu option (orchestrates: versitygw bootstrap + gate → Forgejo →
  Kaneo → runner)
- `docs/services/{forgejo,kaneo,versitygw}.md` + mkdocs nav

## Phased sequence (gated)

- **Phase 0 — prep:** confirm the ZFS dataset + xattr check; confirm Vault paths; confirm
  service hostnames resolve via internal DNS.
- **Phase 1 — versitygw (bootstrap, TrueNAS, local state):** dataset → Custom App → buckets →
  **`s3-lock-probe.sh` exit 0 (HARD STOP otherwise)** → root keys to Vault → ZFS snapshots on.
- **Phase 2 — Forgejo:** job + TLS + CSI + Vault; admin/automation token by CLI; Authentik
  OIDC + group→team; org + repos; import `lab-templates`.
- **Phase 3 — Kaneo:** job + TLS + CSI + Vault; Authentik OIDC; seed.
- **Phase 4 — runner:** DinD job; registration token; Proxmox CI token as secret; trivial
  workflow green.
- **Later (separate brief):** migrate proxmox-lab IaC → OpenTofu + S3 state in versitygw +
  Actions pipelines; mirror/cut over proxmox-lab into self-hosted Forgejo.

## Secrets & security

- Nothing secret committed — all via Vault (`secret/forgejo|kaneo|versitygw`, CI token).
- Registration disabled on every service; Authentik is the front door.
- CI runner token is apply-capable and **distinct** from the read-only Pulse token; DinD, not
  host socket; one runner per environment.
- versitygw root keys mirrored to Vault; state objects protected by ZFS snapshots (no bucket
  versioning — that's the config that breaks conditional writes elsewhere).

## Open follow-ups (not this branch)

- `LAB-TEMPLATES-IAC`: the IaC authoring + state migration (local → S3) + CI pipelines.
- Self-hosting proxmox-lab in Forgejo (GitHub → mirror or cutover).
- Kaneo IdP group mapping remains manual until/if upstream adds group claims.
