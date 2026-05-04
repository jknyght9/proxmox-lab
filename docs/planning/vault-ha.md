# Vault HA — 3-node integrated Raft cluster

> **Status:** Deferred. To be picked up on the next clean cluster rebuild.
> **Branch:** `feature/vault-ha` (this branch holds only the plan; implementation lands here when work begins).
> **Date drafted:** 2026-05-04 (during refactor/v2 deploy stabilization).

## Context

Today Vault is a single-instance Nomad job hard-pinned to `nomad01`, with `file` storage on GlusterFS, 1-of-1 Shamir unseal, Nomad's WIF integration pointing at `nomad01`'s IP, and DNS routing through Traefik. If `nomad01` (or its Vault container) goes down, every Vault-dependent service — Authentik, Samba AD, Netbox, the new Backup/Tailscale jobs — fails to fetch secrets and either alloc-fails or runs degraded.

The lab has 3 Nomad servers (`nomad01-03`) with shared GlusterFS, so the substrate to spread Vault across all of them is already in place. Goal: make Vault survive any one node going down without manual recovery.

## Why integrated Raft (not Consul / file / others)

- Built into Vault — no extra HA-storage cluster to operate.
- Self-replicating; loses GlusterFS dependency for the Vault data path. (GlusterFS stays for everything else; Vault gets its own Raft replication.)
- Native cluster awareness — request forwarding, snapshots, peer auto-join via retry_join.
- Works with our existing Shamir unseal flow; no cloud KMS needed.

## Recommended end-state

```
                ┌─────────────────────────────────────┐
                │       Traefik (HA via VIP)          │
                │     vault.iotvf.lab → :8200         │
                └───────────────┬─────────────────────┘
                                │ load-balances
       ┌────────────────────────┼────────────────────────┐
       ▼                        ▼                        ▼
  ┌──────────┐             ┌──────────┐             ┌──────────┐
  │ nomad01  │             │ nomad02  │             │ nomad03  │
  │ vault    │◀═══raft═══▶ │ vault    │◀═══raft═══▶ │ vault    │
  │ leader   │             │ follower │             │ follower │
  │ /data/   │             │ /data/   │             │ /data/   │
  │ vault    │             │ vault    │             │ vault    │
  │ (LOCAL)  │             │ (LOCAL)  │             │ (LOCAL)  │
  └──────────┘             └──────────┘             └──────────┘
```

- 3-node Raft cluster, one Vault per Nomad node (`type = "system"` or 3-count `service`).
- Storage moves from `file` on GlusterFS to `raft` on each VM's local `/var/lib/vault` (or a per-node subdir under GlusterFS — both work, local disk is simpler).
- Shamir 1-of-3 (one key, threshold 1) keeps the existing operational model — operator unseals each node once after a cold start.
- Nomad's `vault {}` stanza points at `https://vault.iotvf.lab:8200` (Traefik-fronted) so any single Vault going away doesn't matter.
- Backup uses `vault operator raft snapshot` (consistent, atomic) instead of tar-of-file-storage.

## Tradeoffs and decisions

1. **Auto-unseal vs. manual.** Full automation needs a transit/KMS keypair somewhere durable. Recommendation: stay with Shamir manual-unseal, but extend `unsealVault.sh` to walk all 3 nodes. Cold start = 3 unseal calls, but no extra infra.
2. **Migration vs. greenfield.** Two paths:
   - **a)** Snapshot existing single-node Vault → deploy 3-node Raft → restore → re-init dynamic auth. ~30 min downtime; preserves all current secrets.
   - **b)** Wait for next clean rebuild and bring up Raft from day one. Zero migration risk.

   For a lab still under heavy churn, **(b) is much safer**. This branch assumes (b).
3. **Local disk vs. GlusterFS for Raft data.** Raft expects fast local fsync. GlusterFS works but adds latency and risks partial-write weirdness. Local disk per-node is the standard pattern. Operationally fine — Raft does the replication.

## Implementation outline

### Phase 1: Job template restructure
**File:** `terraform/services/templates/vault.nomad.hcl.tpl` (or keep in Layer 1 with a feature flag)

- Drop `constraint { value = "nomad01" }`.
- `count = 3` (or `type = "system"`).
- Per-instance `node_id` from `${node.unique.name}`.
- Storage stanza:
  ```hcl
  storage "raft" {
    path    = "/data/vault"
    node_id = "${node.unique.name}"
    retry_join { leader_api_addr = "https://nomad01.${dns_postfix}:8200" }
    retry_join { leader_api_addr = "https://nomad02.${dns_postfix}:8200" }
    retry_join { leader_api_addr = "https://nomad03.${dns_postfix}:8200" }
  }
  ```
- `api_addr` / `cluster_addr` keep the `{{ sockaddr ... }}` template — already correct for HA.
- Per-node bind-mount: either `/srv/gluster/nomad-data/vault/${node.unique.name}` (separate dirs on shared FS) or a non-gluster volume claim. Local disk preferred.

### Phase 2: Cert + DNS
**Files:** `terraform/services/tls-certificates.tf`, `terraform/services/dns-records.tf`

- Add `nomad02.${dns_postfix}` / `nomad03.${dns_postfix}` + IPs to Vault listener cert SANs, OR reuse the existing `*.${dns_postfix}` wildcard cert (simpler).
- DNS already routes `vault.${dns_postfix}` through Traefik; once `count = 3`, Nomad's service registry lists all instances and Traefik picks them up automatically.

### Phase 3: Init / unseal flow
**Files:** `lib/deploy/nomadJob/initVault.sh`, `lib/deploy/nomadJob/unsealVault.sh`, `setup.sh`

- `initAndUnsealVault`: init runs once on the first booted node (auto-elects leader). Save key + token (unchanged). Then unseal each node in turn — 02 and 03 join via `retry_join` after they're unsealed.
- `unsealVault`: iterate all Vault instances from Nomad's service catalog instead of single IP. Idempotent.
- `setup.sh` Phase 3: wait for ALL 3 to report `sealed=true`, unseal each, verify all `sealed=false`.

### Phase 4: Nomad WIF
**File:** `terraform/services/nomad-vault-integration.tf`

- Change `vault_addr` in each Nomad's `/etc/nomad.d/vault.hcl` from a hardcoded IP to `https://vault.${dns_postfix}:8200` (Traefik-fronted). Internal CA still issues the listener cert, so the existing trust-store push is unchanged.

### Phase 5: Backup
**File:** `terraform/services/templates/backup.nomad.hcl.tpl`

- Replace `tar -czf vault.tar.gz /data/vault` with `vault operator raft snapshot save` against `https://vault.${dns_postfix}:8200`, authed via WIF.
- Document restore: `vault operator raft snapshot restore` against a freshly initialized Vault.

### Phase 6: Documentation
**File:** `.claude/CLAUDE.md`

- Update Vault Configuration: 3-node Raft, manual Shamir across all nodes, Traefik-fronted DNS, raft-snapshot backups.
- Operational note: cold-cluster start = 3 unseal calls.
- Troubleshooting: "one Vault sealed, others fine" — forward unseal to the right node.

## Files Summary

| File | Action | Purpose |
|------|--------|---------|
| `terraform/services/templates/vault.nomad.hcl.tpl` | new (move from Layer 1) | Raft, count=3, retry_join |
| `terraform/templates/vault.nomad.hcl.tpl` | deprecate or feature-flag | Keep single-node bootstrap path optional |
| `terraform/services/tls-certificates.tf` | modify | SANs for all 3 nodes |
| `terraform/services/nomad-vault-integration.tf` | modify | `vault_addr` → DNS |
| `lib/deploy/nomadJob/initVault.sh` | modify | Unseal all 3 after init |
| `lib/deploy/nomadJob/unsealVault.sh` | modify | Walk all instances |
| `setup.sh` (Phase 3 of deployAll) | modify | Wait+unseal all 3, verify all open |
| `terraform/services/templates/backup.nomad.hcl.tpl` | modify | Raft snapshot vs. tar |
| `.claude/CLAUDE.md` | modify | Doc the new model |

## Verification

1. `nomad job status vault` shows 3 running allocs across nomad01/02/03.
2. `vault operator raft list-peers` shows 3 voters, one leader.
3. Stop nomad01's Vault alloc; Authentik/Samba/Netbox keep working — Traefik routes to a survivor.
4. After full cluster reboot: `unsealVault.sh` opens all 3, `vault status` shows sealed=false everywhere.
5. `vault operator raft snapshot save /tmp/test.snap` produces a non-empty file.
6. Backup job logs show snapshot creation; snapshot lands in NFS/SMB target.

## Picking this up

When ready to implement:

```fish
git checkout feature/vault-ha
git rebase main          # or refactor/v2 if v2 hasn't merged yet
# implement against this plan
```

Coordinate with: next clean cluster rebuild (greenfield path 2b above).
