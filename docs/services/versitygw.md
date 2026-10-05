# versitygw — S3 state/object backend (bootstrap)

S3-compatible gateway (`versitygw`, posix backend) that holds the **OpenTofu/Terraform
state** and **Packer** buckets. It is the one **bootstrap** service in the
lab-management set: deployed outside Nomad and outside the state it serves (a state
backend can't be managed by the orchestrator/state that will depend on it).

## Where it runs

**TrueNAS catalog app** (`versitygw`, `community` train), on an **ixVolume ZFS
dataset** for its bucket storage. That gives native **xattrs**, **ZFS snapshots** as
the state-undo, and full visibility in the TrueNAS **Apps + Datasets UI** (TrueNAS
owns the lifecycle and backups). S3 API on **:7070**.

## Why it isn't a Nomad/CSI job

versitygw's posix backend stores object metadata in **filesystem xattrs** and
implements conditional writes (`If-None-Match: *` → state locking) with **advisory
lock files**. Both need a real **local** filesystem. **Advisory locking over NFS
silently breaks** — a lock that doesn't hold is worse than none — so the data
directory must never be CSI/NFS. The TrueNAS ixVolume (local ZFS) satisfies this;
the probe below proves it.

## Deploy (repeatable)

Installed via the TrueNAS app API by `bootstrap/versitygw/truenas-install.sh`
(idempotent — skips if the app exists). Root keys come from Vault `secret/versitygw`.

```sh
export TRUENAS_ADDR=<nas-ip> \
       TRUENAS_API_KEY=<key> \
       VAULT_ADDR=<vault> VAULT_TOKEN=<token> \
       API_PORT=7070
bootstrap/versitygw/truenas-install.sh
```

It creates the app + an ixVolume dataset named `buckets`, published on the API port.
Then create the buckets and run the gate (aws CLI, or `amazon/aws-cli` via Docker):

```sh
for b in tfstate packer; do
  aws --endpoint-url http://<nas-ip>:7070 s3api create-bucket --bucket "$b"
done
tools/s3-lock-probe.sh http://<nas-ip>:7070 tfstate     # must exit 0
```

*(Non-TrueNAS fallback: `bootstrap/versitygw/docker-compose.yml` runs the same image
by hand on any host with a local-disk `./data` — never NFS.)*

## The gate (blocks everything downstream)

`tools/s3-lock-probe.sh` must exit 0 — a real **412 PreconditionFailed** on the
second `If-None-Match: *` write, i.e. conditional writes are enforced. **Anything
else is a hard stop**; no OpenTofu state may be written until it passes. Keep ZFS
snapshots on the dataset; do **not** enable S3 bucket versioning (that is the setting
that breaks conditional writes on other implementations).

## Facts

| | |
|---|---|
| Form | TrueNAS catalog app, `versitygw` / `community` train |
| Storage | ixVolume **ZFS** dataset `buckets` (xattrs + snapshots), never NFS |
| S3 API | `http://<nas-ip>:7070` (webui 30355, admin 30158) |
| Buckets | `tfstate`, `packer` |
| Secrets | Vault `secret/versitygw` (access/secret key, endpoint) |
| Installer | `bootstrap/versitygw/truenas-install.sh` (API, idempotent) |
| Gate | `tools/s3-lock-probe.sh` |

State migration (local → S3) and OpenTofu adoption are a **separate** effort; this
only stands the backend up, buckets ready-but-unused.
