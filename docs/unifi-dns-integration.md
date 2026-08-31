# UniFi DNS Integration (feature/unifi-dns)

**Status:** design / in-flight (started 2026-08-31)
**Goal:** Replace the fragile Pi-hole + nebula-sync mechanism for **authoritative
local DNS records** with UniFi local DNS, optionally managed by the `unifi-dns`
tool (github.com/jknyght9/unifi-dns).

## Why

The 2026-08-31 outage (`auth.iotvf.lab` and all `*.iotvf.lab` → NXDOMAIN) was
caused by dns-01's LXC rootfs filling to 100% (a 2 GB unrotated `pihole.log`),
which silently prevented `pihole-FTL` from persisting `pihole.toml`. The local
A-records (`dns.hosts`) and upstream were wiped, and the "HA" replica had never
received the records because **nebula-sync** was failing every 5 minutes. Net:
a single overgrown log file on a 4 GB container took down all internal name
resolution.

Root problems this feature removes:
- Local records live on **stateful 4 GB LXCs** vulnerable to disk-full / OOM / wedge.
- **nebula-sync** replica propagation is fragile and was silently failing.
- FTL fails **silently** when it can't persist config.

UniFi local DNS lives on the **always-on gateway (UDM)** — no per-node LXC state,
no replica sync, no disk-full failure class.

## What `unifi-dns` is

- **FastAPI (Python) + React/TS + PostgreSQL 18**, deployed via Docker Compose.
- Manages records on the UniFi gateway via the **UniFi Integration v1 API**
  (`/v2/api/site/{site}/static-dns` + client `local_dns_record` via `/rest/user`).
- Zone-aware organization, **audit log + changesets (rollback)**, **drift detection**
  (catches edits made in the native console), centralized filtering settings.
- **Auth:** OIDC (→ our Authentik) or forward-auth header.
- **Migration:** built-in import from **Pi-hole (API)**, Technitium, or RFC 1035 zone files.
- Env: `UNIFI_API_KEY`, `UNIFI_HOST`, `SESSION_SECRET`, `OIDC_ISSUER/CLIENT_ID/CLIENT_SECRET/REDIRECT_URL`.

## Existing assets we reuse (already in the repo)

| Asset | Where | Notes |
|-------|-------|-------|
| UniFi controller addr | `unifi_address = 192.168.100.1` (tfvars) | UDM gateway on the mgmt net |
| UniFi API key | Vault `secret/unifi` (`vault_kv_secret_v2.unifi`) | today used by netbox-sync |
| UniFi site | `unifi_site = default` | |
| Record set (source of truth) | `terraform/services/dns-records.tf` `local.dns_records` | 21 records, IP+name+FQDN |
| Service pattern | `terraform/services/templates/*.nomad.hcl.tpl` | Traefik + Vault WIF + Authentik OIDC |

## Two layers (decouple them)

### Layer 1 — Records onto the UniFi gateway  *(the operational fix)*
Push the same `local.dns_records` set to the UniFi **static-dns** API instead of
(or in addition to) `pihole-FTL --config dns.hosts`. The gateway is always up, so
this alone removes the outage class. Mechanism options:
- **(1a)** New Terraform resource that PUTs records to `/v2/api/site/{site}/static-dns`
  (mirrors how `dns-records.tf` renders `local.dns_records`; reuses `unifi_address`,
  `secret/unifi`, `unifi_site`). No app required.
- **(1b)** Use `unifi-dns`'s Pi-hole import to pull current records into UniFi once.

### Layer 2 — `unifi-dns` app  *(management/governance, optional/additive)*
Deploy the tool for the UI, audit, changesets, and drift detection over those
records. Deployment options:
- **(2a) Nomad job** — fits lab IaC: Traefik route (`unifi-dns.iotvf.lab`), Vault WIF
  for secrets, Postgres on gluster, Authentik OIDC. Requires translating upstream
  compose → Nomad jobspec (FastAPI + React + Postgres tasks).
- **(2b) Standalone docker-compose host** (small VM/LXC) — matches upstream exactly,
  simplest to stand up and track upstream, but off the Nomad pattern.

## Pi-hole disposition (scope decision)

Pi-hole currently also provides **ad-blocking** and **unbound DoT** upstream.
UniFi can do content filtering / ad-blocking too. Options:
- **Full retire** — UniFi owns local records + filtering; decommission the 3 LXCs,
  nebula-sync, and `dns-records.tf` pihole path.
- **Split** — UniFi owns authoritative local records (fixes HA); keep Pi-hole for
  ad-blocking + unbound DoT, pointed at UniFi for local names. Smaller blast radius.
- **Decide later** — do Layer 1 now, keep Pi-hole as-is (already hardened: records
  restored on all 3 nodes + logrotate installed 2026-08-31), revisit after validation.

## Proposed sequence (once decisions are made)

1. Vault: add `secret/unifi-dns` (SESSION_SECRET, OIDC client) + policy; reuse `secret/unifi` for the API key.
2. Layer 1: Terraform resource pushing `local.dns_records` → UniFi static-dns; verify resolution via the gateway.
3. Cutover: point clients / Pi-hole conditional-forward at UniFi for local names; validate `auth`, `vault`, etc.
4. (If chosen) Layer 2: deploy `unifi-dns` app (Nomad or compose) with Authentik OIDC + Traefik.
5. Retire nebula-sync + Pi-hole DNS-record path per the disposition decision; gate `pihole_nebula_sync` in `dns-records.tf`.

## Decisions (2026-08-31)
- **Records→UniFi:** via the **`unifi-dns` app's built-in Pi-hole import** (1b) — run
  once from the UI after the app is up, to seed UniFi static-dns from the current
  (restored) Pi-hole records.
- **App deployment:** **Nomad job** (2a) — Traefik route, Vault WIF, Postgres on
  gluster, Authentik OIDC. Requires translating upstream compose → Nomad jobspec.
- **Pi-hole disposition:** **decide later** — keep the (now hardened) Pi-hole nodes
  running; revisit retire/split after UniFi resolution is validated.
- **UniFi API key:** reuse `secret/unifi` initially (dedicated key can come later).

## Upstream topology (resolved from docker-compose.yml)

| Service | Image | Port | Notes |
|---------|-------|------|-------|
| db | `postgres:18-alpine` (published) | 5432 (→5433 host) | user/db `unifidns`, `POSTGRES_PASSWORD`; vol `/var/lib/postgresql` |
| backend | **build `./backend`** (FastAPI) | 8000 | `DATABASE_URL`, `UNIFI_*`, `SESSION_SECRET`, `OIDC_*`, `CORS_ORIGINS`; depends_on db healthy |
| frontend | **build `./frontend`** (nginx SPA) | 80 (→8080 host) | serves SPA, **reverse-proxies `/api/` → `backend:8000`**; depends_on backend |

Frontend is the only ingress; backend is internal. Under Nomad **host networking**
all tasks share the netns, so the frontend nginx upstream is overridden from
`backend:8000` → `127.0.0.1:8000` (mounted `default.conf`, same trick as netbox's
unit config). Backend env `UNIFI_API_KEY` reuses Vault `secret/unifi`; app secrets
(`SESSION_SECRET`, OIDC client) live in new `secret/unifi-dns`.

## ⚠️ Image gate (hard prerequisite for the Nomad path)

`backend` and `frontend` are **built from source** — there are **no published images**,
and Nomad's docker driver **pulls, it cannot build**. So before the job can run, the two
images must be published to a registry the Nomad nodes can pull. Options:
- **GHCR via CI (recommended)** — add a GitHub Actions workflow to the `unifi-dns` repo
  that builds+pushes `ghcr.io/jknyght9/unifi-dns-backend` and `-frontend` on tag/release.
  Clean, versioned, reproducible; the jobspec pins a tag.
- **Local build+push to a lab registry** — `docker build` both, push to an in-lab registry
  (would need to stand one up) or Docker Hub. Faster to bootstrap, less clean.

The jobspec `terraform/services/templates/unifi-dns.nomad.hcl.tpl` parameterizes both
images via `${unifi_dns_backend_image}` / `${unifi_dns_frontend_image}` so it's ready
once the registry path is chosen.

## Build order (implied by the above)
0. **Publish images** (image gate above) — pick GHCR-CI vs lab-registry; set the two image vars.
1. Vault: `secret/unifi-dns` (`postgres_password`, `session_secret`, `oidc_client_id/secret`,
   `oidc_issuer`) + policy + WIF role `unifi-dns`; reuse `secret/unifi` for `api_key`.
2. Nomad job `unifi-dns.nomad.hcl.tpl` (✅ v1 scaffold committed): PG18 + backend + frontend;
   gluster PG volume + wait-for-gluster; nginx upstream override; Traefik `unifi-dns.<postfix>`.
   Confirm node pin + host ports (8090/8000/5434) against the live cluster at deploy.
3. Authentik: OIDC provider + application for unifi-dns
   (redirect `https://unifi-dns.<postfix>/api/auth/callback`).
4. DNS record `unifi-dns.<postfix>` → Traefik VIP; wire into `nomad-jobs.tf` + `variables.tf`.
5. Deploy; from the UI run **Pi-hole import** (source = dns-01) → verify records land in UniFi.
6. Validate resolution via the UniFi gateway; then revisit Pi-hole disposition.

## Open items
- Does the backend image auto-run `alembic upgrade head` on start? (repo has `alembic/`).
  If not, add a prestart migration task. Verify from `backend/Dockerfile` entrypoint.
- Node/port allocation on the live cluster (avoid PG 5433 collision with netbox on nomad03).
