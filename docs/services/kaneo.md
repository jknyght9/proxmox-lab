# Kaneo

Kaneo is a self-hosted, open-source project-management board (projects, Kanban
boards, tasks, labels). It is deployed as a first-class Layer-2 Nomad service,
mirroring the Netbox/Forgejo pattern: a PostgreSQL sidecar plus the single Kaneo
app container, Postgres state on a CSI/NFS volume (snapshotted on the
cluster_state NAS), secrets via Vault Workload Identity, HTTP fronted by Traefik
with a Vault-PKI wildcard cert, and SSO via Authentik custom-OIDC.

## Overview

| Property | Value |
|----------|-------|
| **Nomad Job** | `kaneo` |
| **Node** | Pinned to `nomad03` |
| **HTTP Port** | 5173 (fronted by Traefik at `tasks.<dns-suffix>`) |
| **Postgres Port** | 5436 (host static, distinct from netbox 5433 / unifi-dns 5434 / forgejo 5435) |
| **Vault Role** | `kaneo` (WIF) |
| **Storage** | CSI/NFS volume `kaneo-pg-data` (Postgres only; the app holds no durable on-disk state) |
| **Secrets** | `secret/kaneo` and `secret/kaneo-oidc` in Vault |
| **Images** | `postgres:16-alpine` + `ghcr.io/usekaneo/kaneo:2.30.1` |

!!! note "Image pins"
    Postgres is pinned to `16-alpine` to match upstream's compose (NOT 17). The
    app is pinned to the exact release `2.30.1` (the container tag drops the
    leading `v` from the `v2.30.1` GitHub release). Change the tags in
    `terraform/services/templates/kaneo.nomad.hcl.tpl` to move versions.

## Deployment

Kaneo is gated behind `deploy_kaneo` (default `false`). Enable it from the
developer menu:

```bash
./setup.sh --dev
# d18) Deploy Kaneo (project-management board)
```

This flips `deploy_kaneo = true` in `terraform/services/terraform.tfvars` and
runs the Layer-2 apply, which:

1. Creates the NFS dataset/share on the cluster_state NAS (`kaneo-pg`) and
   registers it as a CSI volume.
2. Writes `secret/kaneo` (postgres password + auth secret) and the empty
   `secret/kaneo-oidc` placeholder to Vault, plus the `kaneo` policy and WIF role.
3. Deploys the `kaneo` Nomad job (Postgres sidecar + Kaneo app) pinned to nomad03.
4. On the next Authentik configure pass, creates the Authentik OAuth2 provider +
   application and writes the client secret to `secret/kaneo-oidc`. The job then
   restarts (change_mode=restart) and the `CUSTOM_OAUTH_*` env block renders.

!!! warning "Prerequisites"
    Kaneo depends on the CSI plugin (`deploy_csi = true`), Vault, and Traefik.
    SSO additionally requires Authentik (`deploy_authentik` + `configure_authentik`).

## Accessing Kaneo

Via DNS (through Traefik):

```
https://tasks.<dns-suffix>
```

Direct access:

```
http://<nomad03-ip>:5173
```

## Secrets

Stored in Vault at `secret/kaneo`:

| Key | Purpose |
|-----|---------|
| `postgres_password` | PostgreSQL database password |
| `auth_secret` | Kaneo token/session signing secret (`AUTH_SECRET`) |

OIDC credentials land in `secret/kaneo-oidc` (written by the Authentik configure
step, not Terraform):

| Key | Purpose |
|-----|---------|
| `oidc_client_id` | `kaneo` |
| `oidc_client_secret` | Authentik-generated client secret |
| `oidc_endpoint` | `https://auth.<dns-suffix>/application/o/kaneo/` |

## Authentication & access (important)

- **OIDC links by verified email only.** The Authentik custom-OIDC provider does
  **not** drive group/role mapping into Kaneo. A user who signs in via Authentik
  is matched to (or creates) a Kaneo account by their verified email address.
- **Membership is manual.** Workspace and project access is granted **by hand in
  the Kaneo UI** after a user's first SSO login. There is no automatic
  group→workspace provisioning.
- **Registration gate.** The job ships with `DISABLE_REGISTRATION=false` so your
  first OIDC account can be created. **Flip it to `true`** (in
  `kaneo.nomad.hcl.tpl`, then redeploy) once onboarding is complete to lock the
  instance to existing accounts.
- The Authentik redirect URI registered for Kaneo is
  `https://tasks.<dns-suffix>/api/auth/oauth2/callback/custom` (strict). It must
  match exactly or the OIDC callback fails.

## Service account (kaneoadmin)

Kaneo's SSO links accounts by verified email only and has no group→role mapping,
so automation (project creation, Forgejo integration) needs a stable
**instance-admin** identity that does not depend on an interactive SSO login.
That identity is `kaneoadmin@<dns-suffix>`, created automatically by
`null_resource.kaneo_admin` (in `terraform/services/kaneo-admin.tf`) on the
Layer-2 apply.

It is stored in Vault at **`secret/kaneo-admin`** — a **separate path** from the
Terraform-managed `secret/kaneo`. This matters: `secret/kaneo` is rewritten to
its fixed `{postgres_password, auth_secret}` on every apply that touches the
Kaneo job's dependency tree, so any out-of-band key stored there would be
clobbered. `secret/kaneo-admin` uses `ignore_changes` and is only ever written
by the bootstrap, never reset.

| Key | Purpose |
|-----|---------|
| `admin_email` | `kaneoadmin@<dns-suffix>` |
| `admin_password` | Generated local password (better-auth sign-in) |
| `admin_user_id` | Kaneo user id |
| `api_key` | User-scoped API key — **use with the `x-api-key` header** |
| `forgejo_gitea_token` | Forgejo PAT for the Kaneo↔Forgejo (Gitea) link (set out-of-band; preserved across re-runs) |

!!! note "How it is created (idempotent)"
    `null_resource.kaneo_admin` (SSH → nomad01) checks whether `kaneoadmin`
    already exists in the Kaneo Postgres DB (`nomad alloc exec -task postgres
    -job kaneo`); if so it exits cleanly. Otherwise it signs up via
    `POST /api/auth/sign-up/email`, promotes the row to `role='admin',
    email_verified=true` in the DB (Kaneo has no admin-promote API — the first
    admin is set directly), signs in, mints a key via
    `POST /api/auth/api-key/create` (header `Authorization: Bearer <session
    token>`), and writes the result to `secret/kaneo-admin`, preserving any
    existing `forgejo_gitea_token`. If Kaneo is unreachable or signup is blocked,
    it logs an actionable message and exits 0 — it never fails the apply.

!!! note "API key header"
    The minted key is **user-scoped** and is sent on API requests with the
    `x-api-key` header (not `Authorization: Bearer`, which is only used for the
    short-lived session token when minting the key).

## Access policy / lockdown

Kaneo has two independent registration gates. We lock down **local
password** signup while keeping **OIDC onboarding** open:

| Env var | Set to | Blocks | Does **not** block |
|---------|--------|--------|--------------------|
| `DISABLE_PASSWORD_REGISTRATION` | `true` | New local email+password signups | OIDC/SSO account creation; **the initial admin** (upstream-exempted, so `kaneoadmin` can still bootstrap) |
| `DISABLE_REGISTRATION` | `false` | *(when true)* **all** new accounts, OIDC included | — (kept `false` so SSO users can onboard) |

So with `DISABLE_PASSWORD_REGISTRATION=true` + `DISABLE_REGISTRATION=false`, the
only way in for a new human is Authentik SSO, but the `kaneoadmin` bootstrap
still succeeds because the first admin is exempt from the password-registration
gate.

!!! note "Private webhook destinations"
    `KANEO_ALLOW_PRIVATE_WEBHOOK_DESTINATIONS=true` lets Kaneo register and call
    webhooks on **private/internal** hosts (e.g. the in-cluster Forgejo at
    `git.<dns-suffix>`). Without it, Kaneo's SSRF guard refuses the integration.
    This is the Kaneo-side half of the Forgejo link prerequisites below.

## Linking a project to Forgejo (Gitea integration)

!!! info "Site-specific — this is a runbook, not codified"
    The concrete org/repo/workspace values are site-specific and live in the
    overlay, not this repo. The steps below use placeholders `<org>`, `<repo>`,
    `<workspace>`. Kaneo's Gitea integration drives **Forgejo issues → Kaneo
    tasks** sync (default `syncRules` accept everything). Authenticate API calls
    with the `kaneoadmin` key (`x-api-key: <secret/kaneo-admin api_key>`).

**Prerequisites** (both sides must allow private hosts):

- Forgejo: `FORGEJO__webhook__ALLOWED_HOST_LIST=private` (so Forgejo will deliver
  webhooks to the internal Kaneo host).
- Kaneo: `KANEO_ALLOW_PRIVATE_WEBHOOK_DESTINATIONS=true` (so Kaneo accepts a
  webhook pointed at the internal Forgejo host).

**Steps:**

1. **Create the Kaneo project:**

    ```bash
    curl -sk -X POST https://tasks.<dns-suffix>/api/project \
      -H "x-api-key: <api_key>" -H "Content-Type: application/json" \
      -d '{"name":"<repo>","slug":"<repo>","icon":"folder","workspaceId":"<workspace>"}'
    # -> { "id": "<projectId>", ... }
    ```

2. **Create the Gitea integration on that project** (use a Forgejo PAT scoped
   `read:repository, read:user, write:issue` — e.g. `forgejo_gitea_token` in
   `secret/kaneo-admin`):

    ```bash
    curl -sk -X POST https://tasks.<dns-suffix>/api/gitea-integration/project/<projectId> \
      -H "x-api-key: <api_key>" -H "Content-Type: application/json" \
      -d '{"baseUrl":"https://git.<dns-suffix>","accessToken":"<forgejo PAT>",
           "repositoryOwner":"<org>","repositoryName":"<repo>"}'
    # -> { "id": "<integrationId>", "webhookSecret": "<secret>", ... }
    ```

3. **Register the Forgejo webhook** (Kaneo does **not** auto-register it) pointing
   at the integration's webhook endpoint, using the returned `webhookSecret`:

    ```bash
    curl -sk -X POST https://git.<dns-suffix>/api/v1/repos/<org>/<repo>/hooks \
      -H "Authorization: token <forgejo PAT>" -H "Content-Type: application/json" \
      -d '{"type":"gitea","active":true,
           "events":["push","issues","issue_comment","pull_request"],
           "config":{"url":"https://tasks.<dns-suffix>/api/gitea-integration/webhook/<integrationId>",
                     "content_type":"json","secret":"<webhookSecret>"}}'
    ```

!!! note "Sync direction + rules"
    The default `syncRules` are accept-all, so Forgejo issues flow in as Kaneo
    tasks. Adjust the integration's `syncRules` if you want to filter.

## Board model gotchas

- **Column slugs are fixed at creation.** Kaneo derives a column's internal slug
  from its name when the column is created. **Do not rename the default
  columns** (e.g. To Do / In Progress / Done) after the fact — renaming changes
  the display name but the underlying slug stays, which is confusing and can
  break automation/filters that key off the slug. Create new columns with the
  names you want instead.
- **Labels are rows, not swimlanes.** Kaneo models labels as tags on task rows;
  there are no Kanban swimlanes. Plan your taxonomy around labels + columns.

## Configuration

Kaneo is configured entirely via environment variables rendered from Vault into
the job template:

- `KANEO_CLIENT_URL=https://tasks.<dns-suffix>` — public base URL.
- `DATABASE_URL=postgresql://kaneo:<pw>@127.0.0.1:5436/kaneo` — the co-located
  Postgres sidecar (set explicitly; the image would otherwise derive it, but the
  non-default port makes an explicit value clearest).
- `AUTH_SECRET` — token/session signing secret from Vault.
- `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` — database credentials.
- `CUSTOM_OAUTH_*` + `CUSTOM_AUTH_PKCE=true` — the Authentik custom-OIDC block,
  emitted **only** once `secret/kaneo-oidc` is populated (so first boot comes up
  clean without a half-configured provider).
- `NODE_EXTRA_CA_CERTS=/local/certs/root_ca.crt` — Kaneo is Node.js, so it trusts
  the internal CA via `NODE_EXTRA_CA_CERTS` (**not** `SSL_CERT_FILE`, which Node
  ignores). The root CA is mounted from Vault PKI (`pki/cert/ca`).

## Troubleshooting

### Kaneo not accessible

```bash
ssh labadmin@nomad03 "nomad job status kaneo"
ssh labadmin@nomad03 "nomad alloc logs -job kaneo"
```

### Traefik route missing

```bash
curl http://nomad01:8081/api/http/routers | jq . | grep kaneo
nomad service list | grep kaneo
```

### Database connection errors on first start

The Postgres sidecar runs as a prestart sidecar, but first-run image pulls can
delay it. Check the postgres task logs if Kaneo never comes healthy:

```bash
ssh labadmin@nomad03 "nomad alloc logs -job -task postgres kaneo"
```

### OIDC login fails

Confirm `secret/kaneo-oidc` is populated (written by the Authentik configure
pass) and that the job has restarted so the `CUSTOM_OAUTH_*` block rendered:

```bash
vault kv get secret/kaneo-oidc
ssh labadmin@nomad03 "nomad alloc logs -job kaneo | grep -i oauth"
```

A `redirect_uri mismatch` from Authentik means the registered redirect URI does
not match `https://tasks.<dns-suffix>/api/auth/oauth2/callback/custom`.
