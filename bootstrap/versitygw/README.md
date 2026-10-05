# versitygw bootstrap

S3 state/object backend. **Not** managed by Nomad or OpenTofu state (it *is* the
state backend). Full runbook + rationale:
[`docs/services/versitygw.md`](../../docs/services/versitygw.md).

**Primary: TrueNAS catalog app** (`versitygw`/`community`, ixVolume ZFS dataset —
snapshots + xattrs + Apps-UI visibility). Repeatable install:

```sh
export TRUENAS_ADDR=<nas-ip> TRUENAS_API_KEY=<key> \
       VAULT_ADDR=<vault> VAULT_TOKEN=<token> API_PORT=7070
./truenas-install.sh
# then: create buckets tfstate+packer, and run the gate:
../../tools/s3-lock-probe.sh http://<nas-ip>:7070 tfstate   # must exit 0
```

Root keys live in Vault `secret/versitygw`.

**Fallback (non-TrueNAS host):** `docker-compose.yml` + `.env` (chmod 600) on any
host with a **local-disk** `./data` (never NFS). `.env` and `data/` are gitignored.
