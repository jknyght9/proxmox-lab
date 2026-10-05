# Forgejo

Forgejo is a self-hosted Git forge (code hosting, pull requests, issues) with
built-in **Forgejo Actions** CI. It is deployed as a first-class Layer-2 Nomad
service, mirroring the Netbox pattern: a PostgreSQL sidecar plus the app, state
on CSI/NFS volumes (snapshotted on the cluster_state NAS), secrets via Vault
Workload Identity, HTTP fronted by Traefik with a Vault-PKI wildcard cert, and
SSO via Authentik OIDC.

## Overview

| Property | Value |
|----------|-------|
| **Nomad Job** | `forgejo` |
| **Node** | Pinned to `nomad03` |
| **HTTP Port** | 3000 (fronted by Traefik at `git.<dns-suffix>`) |
| **Git-SSH Port** | 2222 (host static port, built-in SSH server) |
| **Postgres Port** | 5435 (host static, distinct from netbox 5433 / unifi-dns 5434) |
| **Vault Role** | `forgejo` (WIF) |
| **Storage** | CSI/NFS volumes `forgejo-pg-data` + `forgejo-data-data` |
| **Secrets** | `secret/forgejo` and `secret/forgejo-oidc` in Vault |
| **Image** | `codeberg.org/forgejo/forgejo:16` (see note below) |

!!! note "Image tag"
    The integration brief named `codeberg.org/forgejo/forgejo:11`, but
    verification against codeberg.org shows the 11.x line is superseded — the
    current stable major is 16.x. The job pins the rolling `16` major tag per
    the brief's directive to "pin the current stable major". Change the tag in
    `terraform/services/templates/forgejo.nomad.hcl.tpl` if you want a specific
    patch or the older LTS line.

## Deployment

Forgejo is gated behind `deploy_forgejo` (default `false`). Enable it from the
developer menu:

```bash
./setup.sh --dev
# d17) Deploy Forgejo (Git hosting + Actions)
```

This flips `deploy_forgejo = true` in `terraform/services/terraform.tfvars` and
runs the Layer-2 apply, which:

1. Creates the two NFS datasets/shares on the cluster_state NAS
   (`forgejo-pg`, `forgejo-data`) and registers them as CSI volumes.
2. Writes `secret/forgejo` (postgres + admin passwords) and the empty
   `secret/forgejo-oidc` placeholder to Vault, plus the `forgejo` policy and
   WIF role.
3. Deploys the `forgejo` Nomad job (Postgres sidecar + Forgejo app) pinned to
   nomad03.
4. On the next Authentik configure pass, creates the Authentik OAuth2 provider
   + application and writes the client secret to `secret/forgejo-oidc`.

!!! warning "Prerequisites"
    Forgejo depends on the CSI plugin (`deploy_csi = true`), Vault, and Traefik.
    SSO additionally requires Authentik (`deploy_authentik` + `configure_authentik`).

## Accessing Forgejo

Via DNS (through Traefik):

```
https://git.<dns-suffix>
```

Direct access:

```
http://<nomad03-ip>:3000
```

Git over SSH clones use port 2222:

```
git clone ssh://git@git.<dns-suffix>:2222/<org>/<repo>.git
```

## Secrets

Stored in Vault at `secret/forgejo`:

| Key | Purpose |
|-----|---------|
| `postgres_password` | PostgreSQL database password |
| `admin_password` | Initial admin user password (used in Phase 2b) |

OIDC credentials land in `secret/forgejo-oidc` (written by the Authentik
configure step, not Terraform):

| Key | Purpose |
|-----|---------|
| `oidc_client_id` | `forgejo` |
| `oidc_client_secret` | Authentik-generated client secret |
| `oidc_endpoint` | `https://auth.<dns-suffix>/application/o/forgejo/` |

## Configuration

Forgejo is configured entirely via `FORGEJO__<section>__<KEY>` environment
variables (rendered into `app.ini` on first start). Key settings baked into the
job template:

- `INSTALL_LOCK=true` — skips the web installer.
- `DISABLE_REGISTRATION=true` — Authentik is the front door; no self-signup.
- `actions ENABLED=true` — Forgejo Actions CI enabled.
- `DB_TYPE=postgres`, `HOST=127.0.0.1:5435` — the co-located Postgres sidecar.
- `ROOT_URL=https://git.<dns-suffix>/`, `SSH_PORT=2222`, built-in SSH server.
- Distinct `session COOKIE_NAME` / `security CSRF_COOKIE_NAME`.
- Internal root CA mounted at `/local/certs/root_ca.crt` with `SSL_CERT_FILE`
  and `GIT_SSL_CAINFO` pointed at it, so Forgejo trusts internal HTTPS for OIDC
  discovery against `auth.<dns-suffix>`.

## Phase 2b — post-deploy configuration (manual, deferred)

The first deploy stands up the platform and the Authentik OIDC provider, but
the following are intentionally **not** automated yet and are run once after the
first successful deploy:

1. **Wire up the Forgejo-side OIDC auth source** (reads `secret/forgejo-oidc`):

   ```bash
   # Run inside the forgejo container (nomad alloc exec -task forgejo ...)
   forgejo admin auth add-oauth \
     --name authentik \
     --provider openidConnect \
     --key forgejo \
     --secret "<secret/forgejo-oidc oidc_client_secret>" \
     --auto-discover-url "https://auth.<dns-suffix>/application/o/forgejo/.well-known/openid-configuration" \
     --scopes "openid profile email" \
     --group-claim-name groups
   ```

   The auth source **must** be named `authentik` so its callback matches the
   redirect URI registered in Authentik
   (`https://git.<dns-suffix>/user/oauth2/authentik/callback`).

2. **Create the admin user and an automation token**; store the token in Vault
   at **`secret/forgejo-admin`** (NOT `secret/forgejo` — see below).
3. **Create the org and repos** (`lab-templates`, `proxmox-lab`, `lab-services`)
   and import `lab-templates` history via Forgejo's migration (not a file copy).
4. **Group → team mapping** so Authentik groups drive org/team membership (see
   the AD group → team runbook below).

See `docs/planning/pm-code-repo.md` for the full phased plan. The Forgejo
Actions runner, Kaneo, and versitygw are separate pieces of that plan.

## Admin automation token (`secret/forgejo-admin`)

Forgejo's stable admin automation token (for API/CI use, e.g. the Kaneo↔Forgejo
link) lives in Vault at **`secret/forgejo-admin`**, **not** `secret/forgejo`.

!!! warning "Why not secret/forgejo"
    `secret/forgejo` is `vault_kv_secret_v2.forgejo` — Terraform rewrites it to
    exactly `{postgres_password, admin_password}` on **any** apply whose target
    pulls in the `forgejo` job's dependency tree. Any out-of-band key added to
    `secret/forgejo` (like an automation token) is silently wiped on the next
    apply. `secret/forgejo-admin` (`vault_kv_secret_v2.forgejo_admin`) uses
    `ignore_changes` so it is a durable, apply-safe home.

| Key | Purpose |
|-----|---------|
| `admin_username` | The site-admin username (e.g. `siteadmin`) |
| `automation_token` | Access token with `all` scopes, for API/CI |

**(Re)create the token** (run inside the forgejo container, dropping to the
`git` user — Forgejo refuses root):

```bash
# From nomad01 (local Nomad agent):
nomad alloc exec -task forgejo -job forgejo su-exec git \
  forgejo admin user generate-access-token \
    --username siteadmin --scopes all --token-name automation-stable
```

Then store it in Vault:

```bash
vault kv put secret/forgejo-admin \
  admin_username=siteadmin automation_token=<token>
```

## AD group → team access mapping

!!! info "Site-specific — this is a runbook, not codified"
    The group-team map is **runtime state on the OIDC auth source**, not
    Terraform-managed — the concrete AD group names, org, and teams are
    site-specific and live in the overlay. The steps below use placeholders
    `<org>`, `<team>`, `<AD-Group>`, `<AdminGroup>`, and the auth source id `<N>`.

**Prerequisites:**

- Authentik's Samba-AD LDAP source is syncing AD groups into Authentik.
- The `groups` OIDC scope mapping exists and is attached to the Forgejo OAuth2
  provider — this is codified in `terraform/services/authentik-apps.tf` (it emits
  each user's Authentik group names as a `groups` claim).
- The Forgejo OIDC auth source named `authentik` exists (Phase 2b).

**Steps** (run inside the forgejo container as `su-exec git`):

1. **Enable the groups claim** on the auth source and designate the admin group:

    ```bash
    forgejo admin auth update-oauth --id <N> \
      --scopes "openid profile email groups" \
      --group-claim-name groups \
      --admin-group "<AdminGroup>"
    ```

2. **Create the org teams** in the Forgejo UI (or API) so the map has targets.

3. **Apply the group → team map** (reconciled on each user's next SSO login):

    ```bash
    forgejo admin auth update-oauth --id <N> \
      --group-team-map '{"<AD-Group>": {"<org>": ["<team>"]}}' \
      --group-team-map-removal
    ```

   The JSON shape is `{"<AD-Group>": {"<org>": ["<team>"]}}` — an AD group maps to
   one or more teams within an org.

!!! warning "Caveats"
    - **Keep the `Owners` team OUT of the map.** With `--group-team-map-removal`,
      a user missing from the mapped group is *removed* from the team on next
      login — mapping Owners can lock you out of the org.
    - Mapping is **reconciled on each user's next SSO login**, not immediately.
    - The group-team map is **runtime state on the auth source**, not codified in
      Terraform — re-apply it manually if the auth source is recreated.

## Troubleshooting

### Forgejo not accessible

```bash
ssh labadmin@nomad03 "nomad job status forgejo"
ssh labadmin@nomad03 "nomad alloc logs -job forgejo"
```

### Traefik route missing

```bash
curl http://nomad01:8081/api/http/routers | jq . | grep forgejo
nomad service list | grep forgejo
```

### Database connection errors on first start

The Postgres sidecar runs as a prestart sidecar, but first-run image pulls can
delay it. Forgejo retries its DB connection on boot; check the postgres task
logs if it never comes healthy:

```bash
ssh labadmin@nomad03 "nomad alloc logs -job -task postgres forgejo"
```

### OIDC login fails

Confirm `secret/forgejo-oidc` is populated (it is written by the Authentik
configure pass) and that the Phase 2b auth source named `authentik` exists:

```bash
vault kv get secret/forgejo-oidc
# inside the container:
forgejo admin auth list
```
