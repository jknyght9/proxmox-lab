# Vault HA: auto-unseal on cold boot

## Problem

After a full cold reboot of all 3 Nomad VMs, all 3 Vault HA instances come back **sealed**. The cluster has no leader until a human manually unseals each instance with the key from `crypto/vault-credentials.json`.

This is the third cold-boot finding from the reboot test. The other two are committed (b52597d): gluster mount race fix + Pi-hole DNS switch.

## Why this matters

While sealed:
- `attr.vault.version` is empty on Nomad nodes → `authentik`, `samba-ad`, `lam`, `netbox` filter-out of placement
- `tailscale` JWT login fails → subnet router doesn't come up → remote tailnet access broken
- Nothing using Vault templates (most jobs) can hydrate secrets

So a single power blip = a manual recovery step before the cluster is back to useful.

## Options

| Option | How | Tradeoff |
|---|---|---|
| **A. systemd unit on each Nomad VM** | Cloud-init writes `/etc/vault.d/unseal.key` (mode 600 root) + a `vault-unseal.service` that POSTs to localhost:8200 after vault is up | Unseal key on disk = no real Vault security (anyone with root on a Nomad VM can read it). Standard homelab pattern. |
| **B. Transit auto-unseal** | Stand up a separate Vault on a non-Nomad host (e.g. a DNS LXC) holding the transit key | Most secure. Adds a second Vault to maintain. Bootstrap Vault has the same problem. |
| **C. Manual unseal via setup.sh menu** | Add `d15) Unseal Vault HA after reboot` that POSTs to all 3 instances from `crypto/vault-credentials.json` | Zero new attack surface. Requires a human after every reboot. |

## Recommendation

**A.** Single-tenant homelab — root on a Nomad VM already grants access to every workload's Vault token via WIF, so "key on disk readable by root" doesn't lose meaningful ground.

## Workaround until fixed

```bash
UNSEAL_KEY=$(jq -r '.unseal_key' crypto/vault-credentials.json)
for ip in 10.10.0.14 10.10.0.15 10.10.0.16; do
  curl -sk -X POST -d "{\"key\":\"$UNSEAL_KEY\"}" "https://$ip:8200/v1/sys/unseal" | jq -r '"\(.sealed)"'
done
```

## Related

- b52597d — gluster mount race + DNS bootstrap fixes (same reboot test)
- `project_vault_readiness_followup.md` (memory) — already deferred wait-for-vault prestart pattern (option 2) and poststart unseal-gate (option 3)
