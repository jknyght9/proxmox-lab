# versitygw bootstrap

Hand-deployed S3 state/object backend. **Not** managed by Nomad or OpenTofu state
(it *is* the state backend). Full runbook + rationale:
[`docs/services/versitygw.md`](../../docs/services/versitygw.md).

Quick start on the host (`/opt/lab-services/s3`):

```sh
cp .env.example .env && chmod 600 .env   # then fill the two keys (see .env.example)
docker compose up -d
# create buckets tfstate + packer, then run the gate:
../../tools/s3-lock-probe.sh http://<host>:7070 tfstate   # must exit 0
```

`.env` and `data/` are gitignored — never commit keys or object data.
