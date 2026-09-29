# Pulse

[Pulse](https://github.com/rcourtman/pulse) is a monitoring dashboard for
Proxmox VE, PBS, and TrueNAS — nodes, guests, storage, backups, and alerts.
It is **agentless**: it polls the Proxmox API with a **read-only token**.

Deployed as a single Nomad container behind Traefik, gated on `deploy_pulse`
(default `false`).

## How it's wired

- **Read-only PVE token** — minted by the *infrastructure* layer
  (`terraform/pulse-monitoring.tf`): a privilege-separated `pulse@pve!monitor`
  token with the built-in `PVEAuditor` role cluster-wide, written to Vault at
  `secret/pulse`. The services layer never holds a privileged Proxmox credential.
- **Job** (`terraform/services/templates/pulse.nomad.hcl.tpl`) — image
  `rcourtman/pulse` on `:7655`, node-local `/data` volume, reads `secret/pulse`
  via Vault Workload Identity, Traefik route `pulse.<postfix>`.
- **Auth (default)** — Pulse's own login (`PULSE_AUTH_USER=admin`,
  `PULSE_AUTH_PASS` from `secret/pulse`). SSO (native OIDC against Authentik, or
  forward-auth) can be layered on later.

## Enabling

1. Set in your **overlay** tfvars (not the repo):
   ```hcl
   deploy_pulse = true          # both terraform/ and terraform/services/
   ```
2. Apply the infrastructure layer (mints the token → `secret/pulse`), then the
   services layer (deploys the job).
3. Browse to `https://pulse.<postfix>`, log in as `admin` with the password from
   `vault kv get secret/pulse` (`admin_password`).
4. **Add the Proxmox node** — Settings → Infrastructure → add your cluster using
   the read-only token from `secret/pulse` (`pve_token_id` + `pve_token`). One
   token covers the whole cluster.

> Pulse configures monitored nodes through its UI, so step 4 is a one-time manual
> action. (A fully-headless import via `PULSE_INIT_CONFIG_DATA` exists but needs a
> pre-built encrypted config blob.)

## Relationship to Uptime Kuma

Pulse (white-box infra metrics) is intended to **replace Uptime Kuma** for this
lab. Deploy Pulse, validate it against live data, then retire the Uptime Kuma
job. Until then they can run side by side.

## Configuration knobs

| Variable | Where | Default |
|----------|-------|---------|
| `deploy_pulse` | `terraform/` + `terraform/services/` | `false` |
| `pulse_image` | `terraform/services/` | `rcourtman/pulse:v6.4.1` |
