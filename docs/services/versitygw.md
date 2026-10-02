# versitygw — S3 state/object backend (bootstrap)

S3-compatible gateway (`versity/versitygw:v1.8.0`, posix backend) that holds the
**OpenTofu/Terraform state** and **Packer** buckets. It is the one **bootstrap**
service in the lab-management set: deployed by hand via Docker Compose on a Nomad
VM **host**, deliberately outside Nomad and outside the state it serves (a state
backend can't be managed by the state it holds).

## Why it isn't a Nomad/CSI job

versitygw's posix backend stores object metadata in **filesystem xattrs** and
implements conditional writes (`If-None-Match: *` → state locking) with
**advisory lock files**. Both need a real **local** filesystem. **Advisory locking
over NFS silently breaks** — a lock that doesn't hold is worse than none — so the
data directory must never be CSI/NFS. Here it runs on a Nomad VM's local ext4 disk
(xattrs verified). (ZFS-snapshot durability is a later option: move `/data` to an
iSCSI zvol from TrueNAS, or run versitygw on TrueNAS directly.)

## Deploy (bootstrap, by hand)

On the chosen host (`/opt/lab-services/s3`):

```sh
# 1. keys
printf 'ROOT_ACCESS_KEY_ID=%s\nROOT_SECRET_ACCESS_KEY=%s\n' \
  "lab$(openssl rand -hex 4)" "$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)" > .env
chmod 600 .env

# 2. up
docker compose up -d        # compose file: bootstrap/versitygw/docker-compose.yml

# 3. buckets (aws cli, or amazon/aws-cli via docker)
for b in tfstate packer; do
  aws --endpoint-url http://<host>:7070 s3api create-bucket --bucket "$b"
done
```

Record `ROOT_ACCESS_KEY_ID` / `ROOT_SECRET_ACCESS_KEY` in **Vault at
`secret/versitygw`** immediately.

## The gate (blocks everything downstream)

```sh
tools/s3-lock-probe.sh http://<host>:7070 tfstate     # must exit 0
```

Exit 0 means a real `412 PreconditionFailed` on the second `If-None-Match: *`
write — i.e. conditional writes are enforced. **Anything else is a hard stop**; no
OpenTofu state may be written until it passes.

**Enable ZFS/host snapshots** on the data path — a bad apply is the common state
disaster, and a snapshot is the undo. Do **not** enable S3 bucket versioning (that
is the setting that breaks conditional writes on other implementations).

## Facts

| | |
|---|---|
| Image | `versity/versitygw:v1.8.0` |
| Port | `7070` |
| Data | local disk (`/opt/lab-services/s3/data`), xattrs required, never NFS |
| Buckets | `tfstate`, `packer` |
| Secrets | `secret/versitygw` (root access/secret key) |
| Compose | `bootstrap/versitygw/docker-compose.yml` |
| Gate | `tools/s3-lock-probe.sh` |

State migration (local → S3) and OpenTofu adoption are a **separate** effort; this
only stands the backend up, buckets ready-but-unused.
