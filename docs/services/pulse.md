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

Pulse is unique in spanning **both** Terraform layers: Layer 1 mints the
read-only PVE token into `secret/pulse`, Layer 2 deploys the job that reads it.

**Recommended — the menu handles both layers:**

```bash
./setup.sh --dev      # then choose  d17) Deploy Pulse monitoring
```

`d17` persists `deploy_pulse = true` in the Layer 1 tfvars, applies **only** the
five Pulse resources (targeted — it never plans a change against a VM) to mint
the token, then runs the Layer 2 apply via `enableService "pulse"`.

**Manual equivalent**, if you prefer to drive the layers yourself — set
`deploy_pulse = true` in the two generated tfvars files (`terraform/terraform.tfvars`
and `terraform/services/terraform.tfvars`; these are real gitignored files in the
repo tree, **not** the overlay), then:

```bash
# Layer 1 — mint the token (targeted; no VM changes)
docker compose run --rm terraform apply -auto-approve \
  -target=proxmox_virtual_environment_user.pulse \
  -target=proxmox_virtual_environment_user_token.pulse_monitor \
  -target=proxmox_virtual_environment_acl.pulse_auditor \
  -target=random_password.pulse_admin \
  -target=vault_kv_secret_v2.pulse
# Layer 2 — deploy the job
docker compose run --rm terraform-services apply -auto-approve
```

Then, either way:

1. Browse to `https://pulse.<postfix>`, log in as `admin` with the password from
   `vault kv get secret/pulse` (`admin_password`).
2. **Add the Proxmox node** — Settings → Infrastructure → add your cluster using
   the read-only token from `secret/pulse`: **Token ID** = `pve_token_id`
   (`pulse@pve!monitor`), **Token Value** = `pve_token_secret` (the bare UUID —
   *not* `pve_token`, which is the full `id=uuid` string). Disable SSL
   verification (the API serves an internal-CA cert). Point the host at a
   Proxmox IP reachable from the Nomad network (e.g. the services-subnet IP,
   `https://<pve-ip>:8006`). One
   token covers the whole cluster.

> `deploy_pulse` is preserved across Layer 2 regeneration (`refreshLayer2Configs`
> → `initVault.sh`), so it survives later deploys instead of resetting to `false`.

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
