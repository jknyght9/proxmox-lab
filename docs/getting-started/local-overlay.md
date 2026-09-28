# Local / Site Overlay

`proxmox-lab` is **site-agnostic** — the same code deploys to any Proxmox
environment. Everything specific to *your* deployment lives in a separate
**overlay directory outside this repo**. Nothing site-specific (real domains,
IPs, hostnames, credentials, or credential paths) belongs in a tracked file.

## Why

- **Portability** — deploy the identical codebase to any Proxmox cluster.
- **Safety** — real values never land in the (public) repo history.
- **Private history** — track your site's changes and work-logs separately.

## Recommended layout

Keep the overlay as its own **private git repo**, a sibling of this one:

```
~/proxmox-lab/            # this repo (public, site-agnostic)
~/<site>-lab/             # your overlay (private)   e.g. ~/acme-lab/
├── CLAUDE.md             # site context: topology, IPs, hostnames, cred paths, service inventory
├── bootstrap.yml         # site bootstrap config (single source of truth for setup.sh)
├── terraform/
│   ├── terraform.tfvars              # Terraform variables for this site
│   └── services/
│       └── *.auto.tfvars             # service overlay vars (datasets, ACLs, AD groups, …)
├── crypto/               # SSH keys, Vault credentials (NEVER in the repo)
├── cluster-info.json     # generated topology (network, storage, nodes)
├── hosts.json            # generated host→IP map for DNS records
├── memory/               # cross-session agent memory
└── project-updates/      # dated work-logs / status docs
```

## Repo "slots" (already gitignored)

The repo has placeholders these overlay files fill. `.gitignore` already
excludes every one of them, so a correctly-placed overlay file can never be
committed by accident:

| Repo slot (gitignored) | Filled from overlay |
|------------------------|---------------------|
| `bootstrap.yml` | `~/<site>-lab/bootstrap.yml` |
| `terraform/terraform.tfvars` (`**/*.tfvars`) | `~/<site>-lab/terraform/terraform.tfvars` |
| `terraform/services/lab-*.auto.tfvars` | `~/<site>-lab/terraform/services/*.auto.tfvars` |
| `crypto/` | `~/<site>-lab/crypto/` |
| `cluster-info.json`, `hosts.json` | generated locally (or kept in the overlay) |
| `.claude/*` (except `CLAUDE.md`) | agent state |
| `CLAUDE.local.md` | your overlay pointer (see below) |

## Wiring the overlay into the repo

Symlink (edits flow both ways — recommended) or copy:

```bash
SITE=~/iotvf-lab   # your overlay

ln -sf "$SITE/bootstrap.yml"              ~/proxmox-lab/bootstrap.yml
ln -sf "$SITE/terraform/terraform.tfvars" ~/proxmox-lab/terraform/terraform.tfvars
for f in "$SITE"/terraform/services/*.auto.tfvars; do
  ln -sf "$f" ~/proxmox-lab/terraform/services/
done
ln -sfn "$SITE/crypto" ~/proxmox-lab/crypto          # or keep crypto/ in-repo (gitignored)
```

Point the agent at your overlay:

```bash
cp ~/proxmox-lab/CLAUDE.local.md.example ~/proxmox-lab/CLAUDE.local.md
# edit CLAUDE.local.md → set your overlay path
```

## First-time setup

1. `mkdir ~/<site>-lab && (cd ~/<site>-lab && git init)` — private overlay repo.
2. `cp ~/proxmox-lab/bootstrap.yml.example ~/<site>-lab/bootstrap.yml` and edit
   (Proxmox IP, network CIDR/gateway, DNS suffix, …).
3. Symlink the slots into the repo (above).
4. `cp CLAUDE.local.md.example CLAUDE.local.md` and set your overlay path.
5. `./setup.sh` — reads `bootstrap.yml`, generates `terraform.tfvars` /
   `packer.auto.pkrvars.hcl` / `cluster-info.json`, and deploys.

## What must NEVER be committed to `proxmox-lab`

- Real domains / DNS suffixes, IP addresses, hostnames.
- Credentials or credential paths, API keys, SSH keys, Vault tokens.
- Site-specific Terraform values (put them in the overlay `*.auto.tfvars`).

Placeholders used in docs/examples (`mylab.lan`, `10.1.50.x`, `192.168.1.1`)
are intentional and safe.
