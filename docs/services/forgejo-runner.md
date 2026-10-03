# Forgejo Actions Runner

The Forgejo Actions runner is the CI executor for the [Forgejo](forgejo.md)
forge. It polls Forgejo **outbound** for queued workflow jobs and runs each one
in a throwaway Docker container spun up by a co-located Docker-in-Docker (dind)
daemon. It has **no inbound web UI**, so — unlike the other Layer-2 services —
it is **not** fronted by Traefik and has **no DNS record**.

## Overview

| Property | Value |
|----------|-------|
| **Nomad Job** | `forgejo-runner` (gated on `deploy_forgejo_runner`, default `false`) |
| **Node** | Pinned to `nomad03` (same node as Forgejo) |
| **Runner Image** | `code.forgejo.org/forgejo/runner:13.1.0` |
| **DinD Image** | `docker:28-dind` (privileged, loopback TCP `:2375`) |
| **Vault Role** | `forgejo-runner` (WIF) |
| **Durable state** | CSI/NFS volume `forgejo-runner-data` (`.runner` + config only) |
| **Scratch** | node-local `ephemeral_disk` (dind data-root, CI cache + workdir) |
| **Secrets** | `secret/forgejo-runner` (`registration_token`) in Vault |
| **Registration** | Instance-level (any repo/org can use the runner) |

!!! note "Image + version"
    The integration brief named `code.forgejo.org/forgejo/runner`. The current
    stable runner is **v13.1.0** (released 2026-08-31), pinned exactly in
    `terraform/services/templates/forgejo-runner.nomad.hcl.tpl`. Both
    `code.forgejo.org` and `data.forgejo.org` publish the image; we use
    `code.forgejo.org` per the brief.

## Architecture

```
┌──────────────────────── nomad03 (host netns) ────────────────────────┐
│  forgejo-runner job                                                    │
│                                                                        │
│  ┌──────────────┐  tcp://127.0.0.1:2375   ┌────────────────────────┐  │
│  │  runner task │ ───────────────────────▶│  dind task (sidecar)   │  │
│  │ (poll+exec)  │                          │  docker:28-dind         │  │
│  └──────┬───────┘                          │  privileged, no TLS     │  │
│         │ HTTPS (internal CA)              │  data-root on /alloc    │  │
│         ▼                                   └────────────┬───────────┘  │
│  https://git.<postfix>  ◀───── outbound poll ──┘         ▼              │
│                                             job containers (node:20…)   │
└────────────────────────────────────────────────────────────────────────┘
```

### Docker-in-Docker (not the host socket)

The runner needs a Docker daemon to create job containers. We run our **own**
dind daemon rather than bind-mounting the host's `/var/run/docker.sock`, so CI
workloads are isolated from the host's Nomad-managed containers.

- dind runs **privileged** with `DOCKER_TLS_CERTDIR=""`, so the stock
  entrypoint serves `dockerd` on `tcp://0.0.0.0:2375` (plain) plus the unix
  socket. Because the job uses host networking, the runner reaches it on
  `tcp://127.0.0.1:2375` (loopback only — nothing routes it off-box).
- dind's storage lives at `/alloc/data/docker` (node-local `ephemeral_disk`),
  **never** on NFS — overlayfs does not work on NFS. The trade-off: the image
  layer cache is lost if the alloc is rescheduled to a fresh client, and dind
  simply repopulates it.
- **Port chosen:** `2375`, verified free on nomad03 (alongside 2376/2377) on
  2026-10-03. The co-located services use 3000/2222/5435 (forgejo),
  5173/5436 (kaneo), and 8080/5433/6380/8082 (netbox).

### CA trust

The runner is a Go binary and only ever speaks HTTPS to the **internal**
Forgejo instance (`git.<postfix>`), which is served by Traefik with a Vault-PKI
wildcard cert off the internal root CA. The root CA is pulled from Vault
(`pki/cert/ca`) into `/local/certs/root_ca.crt` via a Nomad template stanza, and
`SSL_CERT_FILE` points the runner at it. (Public image pulls are dind's job, in
its own stock trust store, so the runner never needs public CAs.)

### Labels

A runner label maps a workflow `runs-on:` value to the container image the job
runs in. Defaults baked into the job (extend as workflows need):

```
docker:docker://node:20-bookworm
ubuntu-22.04:docker://node:20-bookworm
ubuntu-latest:docker://node:20-bookworm
```

## Deployment

Gated behind `deploy_forgejo_runner` (default `false`). Enable from the dev menu:

```bash
./setup.sh --dev
# d19) Deploy Forgejo Actions runner (CI executor)
```

This flips `deploy_forgejo_runner = true` in
`terraform/services/terraform.tfvars` and runs the Layer-2 apply, which:

1. Creates the `forgejo-runner` NFS dataset/share on the cluster_state NAS and
   registers it as a CSI volume.
2. Writes the `forgejo-runner` Vault policy + WIF role and the empty
   `secret/forgejo-runner` placeholder.
3. Runs `null_resource.forgejo_runner_token` — mints an **instance-level**
   registration token from the live Forgejo API and writes it to
   `secret/forgejo-runner` (see below).
4. Deploys the `forgejo-runner` Nomad job (dind sidecar + runner), which
   registers once (persisting `.runner` on the NFS volume) and starts polling.

!!! warning "Prerequisites"
    Requires `deploy_forgejo = true` (the forge it serves), `deploy_csi = true`
    (for the state volume), and Vault. The forgejo job must be running so its
    registration token can be generated.

## Registration-token flow

Registration is **instance-level**: a single reusable token lets any repo or
org (including `cifr-lab`) schedule jobs on the runner — the sensible default
for a single-tenant lab.

`null_resource.forgejo_runner_token` (SSH → nomad01):

1. Generates a registration token with Forgejo's own CLI, run inside the
   forgejo container via the local Nomad agent:
   `nomad alloc exec -task forgejo -job forgejo su-exec git forgejo actions generate-runner-token`.
   This runs as the server (no API/admin token needed), `su-exec git` drops
   from root (Forgejo refuses to run as root), and `generate-runner-token` is
   idempotent — it returns the current unused instance token until one is
   consumed. `nomad alloc exec -job` finds the forgejo alloc on whatever node
   it runs, so no node pin is assumed.
2. Writes the token to `secret/forgejo-runner.registration_token`.

The runner job reads `secret/forgejo-runner` via its Vault template and, if no
`.runner` file exists yet, registers with
`forgejo-runner register --no-interactive --instance https://git.<postfix>
--token <token> --labels <labels>`, then runs `forgejo-runner daemon`.

!!! note "Why the CLI, not the admin API"
    The admin API path (`GET /api/v1/admin/actions/runners/registration-token`)
    needs a **site-admin** access token (`read:admin`). The only such token is
    created out-of-band in Forgejo Phase 2b and stored in `secret/forgejo` —
    but that KV secret is Terraform-managed (`vault_kv_secret_v2.forgejo`), so a
    later apply clobbers the out-of-band key and breaks the mint. The CLI runs
    as the server itself, so it has no token dependency and no clobber hazard.

!!! note "First-boot dind race"
    The runner task may restart a couple of times on first boot while the dind
    sidecar's daemon finishes starting (`cannot ping the docker daemon`). This
    self-heals — once dind is accepting connections the runner stays up and
    `[poller] launched` appears in its logs.

## Rotating / re-registering

Re-mint the registration token (e.g. after resetting it in Forgejo) and bounce
the runner:

```bash
# Re-mint + re-store (idempotent; the instance token is stable until reset):
./setup.sh --dev    # d19, or: docker compose run --rm terraform-services apply

# Force a fresh registration (drops the persisted .runner first):
ssh labadmin@nomad03 \
  "sudo rm -f /mnt/<pool>/<dataset_root>/forgejo-runner/.runner"
nomad job restart forgejo-runner
```

Reset the token in the Forgejo UI at **Site Administration → Actions → Runners**
(or the org's **Settings → Actions → Runners**).

## Adding the Proxmox CI token (future, security-gated)

A natural next step is giving CI jobs a **Proxmox API token** so workflows can
build/provision against the cluster. This is intentionally **out of scope** here
and must be handled as a separate, reviewed change:

- Mint a dedicated, least-privilege Proxmox token (its own role, scoped to the
  paths CI actually needs) — **do not** reuse `hashicorp@pam`.
- Store it in Vault (e.g. `secret/forgejo-runner-proxmox`) and expose it to jobs
  as an Actions **secret/variable** in Forgejo, not baked into the job template.
- Review blast radius: an instance-level runner executes code from any repo that
  can queue a job, so a Proxmox token reachable from CI is effectively a
  cluster-admin credential. Gate repo/workflow access accordingly first.

No Proxmox token is created by this integration.

## Troubleshooting

### Runner not picking up jobs

```bash
ssh labadmin@nomad03 "nomad job status forgejo-runner"
ssh labadmin@nomad03 "nomad alloc logs -job -task runner forgejo-runner"
# In the Forgejo UI, the runner should show as 'Idle'/'Active' under
# Site Administration → Actions → Runners.
```

### "No registration token in secret/forgejo-runner"

The token mint could not reach the forgejo job. Verify the forge is running and
re-run the generator:

```bash
vault kv get secret/forgejo-runner   # expect a non-empty registration_token
# Regenerate manually if empty (same command the mint uses):
ssh labadmin@nomad01 "nomad alloc exec -task forgejo -job forgejo \
  su-exec git forgejo actions generate-runner-token"
```

### dind not reachable / jobs fail to start containers

```bash
ssh labadmin@nomad03 "nomad alloc logs -job -task dind forgejo-runner"
# From the runner task, the daemon should answer on loopback:
ssh labadmin@nomad03 "curl -s http://127.0.0.1:2375/_ping"   # -> OK
```

### Jobs can't resolve DNS or reach the internet

dind uses its own default bridge network for job containers. Confirm the dind
daemon came up (`--data-root=/alloc/data/docker`) and that the node has egress.
The runner's own HTTPS to Forgejo is validated against the internal root CA via
`SSL_CERT_FILE=/local/certs/root_ca.crt`.
