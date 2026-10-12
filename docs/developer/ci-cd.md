# CI/CD — Forgejo Actions + Vault AppRole

Deployment repos (`infra-*`, e.g. `infra-role-emba`) run their Terragrunt/OpenTofu
from **Forgejo Actions**: `plan` on PR, `apply` on merge to main. Each repo
authenticates to Vault with its **own AppRole**, fetches a short-lived token, and
reads only the secrets its stack needs. The Vault side is defined in
`terraform/services/vault-ci-approle.tf` (proxmox-lab's lane); the workflow files
live in the consuming repo (lab-templates' lane).

## The pattern

A `var.infra_ci_repos` map — populated from a gitignored `lab-ci-approles.auto.tfvars`
overlay so no repo names land in the tracked repo — drives a `for_each` that mints,
per repo:

- a Vault **AppRole** `<repo>-ci`,
- a least-privilege **read-only policy** `<repo>-ci`, and
- a dedicated **ED25519 CI SSH key** at `secret/ci/<repo>/ssh`.

Every entry is also granted the common read set: `tofu/state-encryption`,
`versitygw`, and its own `ci/<repo>/ssh`. Empty map (the default) = no CI AppRoles.

```hcl
# terraform/services/lab-ci-approles.auto.tfvars  (gitignored overlay)
infra_ci_repos = {
  "infra-role-emba" = {
    secret_read_paths = ["proxmox", "samba-ad/service-accounts", "nas/nas01", "unifi"]
  }
}
```

## Security posture

- **Dedicated CI SSH key** — never `secret/ssh-keys` (that bundles the operator
  `labadmin` *and* `enterprise`/Proxmox-node keys). The CI key is independently
  revocable and doubles as a read-only Forgejo **deploy key** on the module-source
  repo + is injected into VMs the stack provisions.
- **Dedicated Proxmox CI token** at `secret/proxmox` — a `privsep=0` token on
  `hashicorp@pam`, revocable without touching the operator deploy token:
  `pveum user token add 'hashicorp@pam' ci-<repo> --privsep 0`.
- **Non-expiring secret_id, CIDR-bound** to the runner subnet (`10.10.0.0/24`),
  with short issued tokens (`token_ttl=20m`, `token_max_ttl=1h`) — a stolen
  secret_id is useless off-network.

`secret/proxmox` and `secret/versitygw` are **operator-populated** (not in TF), so
no tokens touch tfvars/state. The `tofu/state-encryption` passphrase is **mirrored**
from the existing `secret/opentofu/state-encryption` (CI must use the same key that
already encrypts live state).

## Onboarding a repo (operator runbook)

1. Add the repo to `lab-ci-approles.auto.tfvars` (see above).
2. Mint a dedicated Proxmox CI token, then store it:
   ```bash
   # on a PVE node:
   pveum user token add 'hashicorp@pam' ci-<repo> --privsep 0
   # then (reads the real endpoint from the existing secret/proxmox/api):
   vault kv put secret/proxmox token_id='hashicorp@pam!ci-<repo>' token='<uuid>' \
     api_token='hashicorp@pam!ci-<repo>=<uuid>' endpoint='https://<pve>:8006'
   ```
3. `tf-services apply` the new resources. If Vault already has `approle` enabled
   out-of-band, import it first:
   `tf-services import 'vault_auth_backend.approle[0]' approle`.
4. Pull the credentials:
   ```bash
   tf-services output -json infra_ci_role_ids          # -> role_id
   vault write -f auth/approle/role/<repo>-ci/secret-id  # -> secret_id
   ```
5. Set the repo's **Forgejo secrets**: `VAULT_ROLE_ID`, `VAULT_SECRET_ID`,
   `VAULT_CACERT_B64` (base64 of Vault's PKI root CA — `pki/cert/ca`, *not* any
   other `ca.crt`), `FORGEJO_PR_COMMENT_TOKEN` (low-scope PAT for result comments),
   and `VAULT_ADDR` as a repo **variable** (`https://vault.<domain>:8200`).
6. Register the CI pubkey (`secret/ci/<repo>/ssh` → `public_key`) as a read-only
   **deploy key** on the module-source repo.

## Runners

Two runners serve CI (see [Forgejo Actions Runner](../services/forgejo-runner.md)):

- **`build-large`** → `builder01`, a dedicated build VM (`deploy_builder`) for heavy
  jobs. Its act_runner runs job containers on **host network** (the default bridge
  NAT added ~3s per outbound call, which starved IaC plans making many serial
  Proxmox-API calls).
- **`docker` / `ubuntu-latest`** → the dind runner (a Nomad job) for standard CI.

Jobs route by `runs-on:`.

## Gotchas

- **`approle` already enabled** → first apply errors `path is already in use`;
  import the backend (step 3) and re-apply.
- **State-encryption mismatch** → if `secret/tofu/state-encryption` ever diverges
  from `secret/opentofu/state-encryption`, CI can't decrypt existing state; the TF
  mirror keeps them in sync.
- **Proxmox-API refresh latency** → per-VM `qemu-agent`/status reads can take
  seconds each; a VM-heavy `terragrunt plan` refresh can run long. Mitigations live
  in the consuming module (bpg provider pin, `-refresh=false` on plan, split apply),
  not the runner.
