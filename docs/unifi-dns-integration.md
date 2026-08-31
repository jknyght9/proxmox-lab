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

## Open decisions (see the branch discussion)
- Layer-1 mechanism: Terraform static-dns push (1a) vs unifi-dns import (1b)?
- Deploy the `unifi-dns` app? If yes, Nomad (2a) or compose host (2b)?
- Pi-hole disposition: full retire / split / decide later?
- Dedicated UniFi API key for unifi-dns, or reuse `secret/unifi`?
