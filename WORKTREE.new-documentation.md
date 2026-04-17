# WORKTREE.md — Proxmox Lab: Comprehensive Documentation

> **This file is a strict contract for AI assistants operating in this worktree.**
> **AI MUST read and comply with ALL sections before performing any work.**
> **Violations of OUT OF SCOPE or FORBIDDEN ACTIONS sections are hard failures.**

## Branch
`feature/new-documentation`

## Purpose
Rewrite and expand the MkDocs documentation site to accurately reflect the current state of the proxmox-lab project. The existing docs are stale (they describe the old Docker Swarm architecture) and the `configuration/`, `reference/`, and `troubleshooting/` stub directories are empty. The goal is comprehensive, accurate documentation covering every major component of the project as it exists today.

## Related Issues / Specs
None — personal lab project.

## Scope

### In Scope (ONLY these areas may be modified)
- `docs/` — All markdown documentation files. Existing files may be rewritten. New files may be created. Empty stub subdirectories (`docs/configuration/`, `docs/reference/`, `docs/troubleshooting/`) should be removed and replaced with a proper structure.
- `mkdocs/` — MkDocs Docker build context; may be modified as needed.
- `mkdocs.yml` — Navigation structure and site configuration may be updated to match the new doc structure.
- `WORKTREE.md` — This contract file; may be updated as scope evolves.
- `README.md` — Repo root README; may be updated to reflect current project state.

### Out of Scope (MUST NOT be modified)
- `setup.sh` — Entry point script; read for accuracy, never modified.
- `lib/` — All bash helper and deploy scripts; read-only reference.
- `terraform/` — All Terraform modules and state files; read-only reference.
- `nomad/` — All Nomad job definitions and Vault policies; read-only reference.
- `packer/` — All Packer templates; read-only reference.
- `proxmox/` — Proxmox host setup helpers; read-only reference.
- `compose.yml` — Docker Compose service definitions; read-only reference.
- `.claude/CLAUDE.md` — Project AI instructions; read-only, do not edit.
- `cluster-info.json`, `hosts.json` — Runtime config files; read-only reference.
- `crypto/` — SSH keys and credentials; structure may be documented abstractly (e.g., "this directory contains generated SSH keys and Vault credentials") but actual file contents (keys, passwords, tokens) MUST NOT be read or reproduced.
- `terraform/terraform.tfstate` and all `*.backup` state files — Never read or reference.

## Architectural Constraints
- **Documentation engine**: MkDocs with the Material theme (`mkdocs-material`). All new pages must be valid MkDocs Markdown and use only extensions already declared in `mkdocs.yml` (`pymdownx.superfences`, `pymdownx.tabbed`, `pymdownx.details`, `pymdownx.tasklist`, `pymdownx.highlight`, `pymdownx.inlinehilite`, mermaid fences, etc.).
- **Diagrams**: Use mermaid fences (already configured in `mkdocs.yml`) for architecture and flow diagrams.
- **Accuracy over completeness**: Every technical claim in the docs must be verifiable against the actual codebase. Do not document features, services, or configurations that no longer exist (e.g., Docker Swarm, Portainer, dnscrypt-proxy as a primary component — these are legacy). Read the source files before writing about them.
- **Current architecture**: The project has migrated from Docker Swarm to a 3-node HashiCorp Nomad cluster. Vault, Authentik, Traefik, and Samba AD are deployed as Nomad jobs. Pi-hole v6 (not v5) is used. The `dns.hosts` array in `pihole.toml` (TOML format) is how DNS records are managed — not a legacy hosts file.
- **VMID accuracy**: Document VMID assignments exactly as defined in CLAUDE.md.
- **No secrets in docs**: Do not document actual credential values, token formats that expose secrets, or file contents from `crypto/`. Abstract descriptions of `crypto/` structure and purpose (e.g., what files are generated and why) are allowed.
- **Nav registration**: Every new `.md` file created under `docs/` must be added to the `nav:` section of `mkdocs.yml`.

## Forbidden Actions
- Do NOT modify any file outside `docs/`, `mkdocs/`, `mkdocs.yml`, `WORKTREE.md`, and `README.md`.
- Do NOT read file contents under `crypto/` or reproduce any keys, passwords, or tokens from it. Abstract descriptions of the directory's purpose and file structure are permitted.
- Do NOT read or reference `terraform/terraform.tfstate` or any `.backup` state files.
- Do NOT document Docker Swarm, Portainer, dnscrypt-proxy, or Fedora/Debian cloud images as current components — these are legacy/archived.
- Do NOT invent configuration values, IP addresses, or file paths not present in the codebase.
- Do NOT remove or alter the MkDocs Material theme declaration or markdown extensions already in `mkdocs.yml` — only add to the `nav:` section.
- Do NOT create documentation files outside the `docs/` directory.

## Success Criteria
- [ ] `docs/index.md` accurately describes the current project (Nomad-based, not Docker Swarm).
- [ ] `docs/overview.md` reflects the current `setup.sh` menu and deployment flow.
- [ ] `docs/pre-installation.md` reflects current requirements (Proxmox >=7.x, network bridge config, SDN labnet).
- [ ] `docs/checklist.md` is complete and accurate (not truncated as it currently is).
- [ ] Empty stub directories (`docs/configuration/`, `docs/reference/`, `docs/troubleshooting/`) are removed and replaced with populated content.
- [ ] New documentation exists for: Packer (golden images), Terraform modules (all active modules), Nomad cluster architecture, each Nomad job (Traefik, Vault, Authentik, Samba AD), DNS architecture (Pi-hole v6 + Unbound + Gravity Sync), step-ca / internal PKI, Vault + WIF integration, networking (vmbr0 + labnet SDN), and troubleshooting for each major subsystem.
- [ ] `mkdocs.yml` nav is updated to include all new pages in a logical hierarchy.
- [ ] No legacy/inaccurate content remains in any doc page.
- [ ] All mermaid diagrams render without syntax errors.
- [ ] All internal doc cross-links resolve to real pages.

## Key Context

**What exists today (source of truth — read these files):**
- `setup.sh` — Interactive menu with 17 options; the primary user interface.
- `lib/util.sh` — `sshRun`, `sshScript`, `scpTo` bash helper functions used throughout.
- `lib/deploy/` — Per-service deploy scripts: `deployAuthentik.sh`, `deployTraefik.sh`, `deployVault.sh`, `deployNomad.sh`, `deployKasm.sh`, plus `deployAllServices.sh`, `deployCriticalServices.sh`.
- `lib/deploy/nomadJob/` — Nomad job deploy helpers: `deployVault.sh`, `deployAuthentik.sh`, `unsealVault.sh`.
- `lib/deploy/vm/` — VM deploy helpers: `deployKasm.sh`, `deployNomad.sh`.
- `terraform/main.tf` — Calls modules: `vm-nomad`, `vm-kasm`, `lxc-pihole`, `lxc-step-ca`.
- `terraform/vm-nomad/` — 3-node Nomad cluster with GlusterFS.
- `terraform/vm-kasm/` — Kasm Workspaces.
- `terraform/lxc-pihole/` — Pi-hole v6 with Unbound (DNS-over-TLS) and Gravity Sync.
- `terraform/lxc-step-ca/` — step-ca internal PKI with ACME.
- `nomad/jobs/traefik.nomad.hcl` — Traefik reverse proxy, pinned to nomad01.
- `nomad/jobs/vault.nomad.hcl` — HashiCorp Vault, privileged mode, GlusterFS-backed.
- `nomad/jobs/authentik.nomad.hcl` — Authentik SSO (OAuth2/OIDC/SAML/LDAP), GlusterFS-backed.
- `nomad/vault-policies/authentik.hcl` — Vault policy for Authentik (reads `secret/data/authentik`).
- `nomad/vault-policies/nomad-server.hcl` — Vault policy for Nomad server.
- `packer/build_docker.pkr.hcl` — Base Docker+GlusterFS+acme.sh template (VMID 9001).
- `packer/build_nomad.pkr.hcl` — Nomad+Consul template built on Docker base (VMID 9002).

**Critical architecture facts:**
- All Nomad service jobs (Traefik, Vault, Authentik) are pinned to `nomad01` via hostname constraint.
- Vault uses `disable_mlock = true` (IPC_LOCK not available in Nomad Docker driver).
- Vault-Nomad integration uses Workload Identity Federation (WIF) — JWT-based, no long-lived tokens on nodes.
- Pi-hole v6 uses TOML config (`/etc/pihole/pihole.toml`), not the legacy v5 config format.
- DNS records are stored in the `dns.hosts` array in TOML, not a flat hosts file.
- GlusterFS replicated volume at `/srv/gluster/nomad-data` is the shared persistent storage layer.
- Samba AD: DC01 on nomad01, DC02 on nomad02; Pi-hole forwards AD realm queries to DCs on port 5353/5354.
- Nomad datacenter: `dc1`, region: `global`.
- The `cluster-info.json` file stores network topology at runtime (not committed with real values).
- `crypto/vault-credentials.json` stores unseal key + root token (gitignored).

**What the existing docs got wrong (fix these):**
- `docs/index.md` lists Docker Swarm and Portainer as current features — they are legacy.
- `docs/overview.md` describes Docker Swarm deployment — replace with Nomad cluster deployment.
- `docs/overview.md` lists Debian 12, Fedora Cloud 42 cloud images — these are legacy; current base is Ubuntu 24.04 (VMID 9999) with Packer-built templates (VMIDs 9001, 9002).
- `docs/checklist.md` is truncated mid-sentence.
- `docs/pre-installation.md` references `dnscrypt-proxy` as a component alongside Unbound — current stack uses Unbound only for recursive DNS; verify in Terraform module before documenting.

## Dependencies & Related Worktrees
None. This is a standalone documentation branch. No infrastructure changes are required.

## Task Checklist
- [ ] Read all in-scope source files listed under Key Context before writing any page (do not document from memory).
- [ ] Remove empty stub directories: `docs/configuration/`, `docs/reference/`, `docs/troubleshooting/`.
- [ ] Rewrite `docs/index.md` — accurate project overview, current feature list (Nomad-based), requirements, license.
- [ ] Rewrite `docs/overview.md` — current `setup.sh` menu (17 options), high-level deployment flow.
- [ ] Rewrite `docs/pre-installation.md` — current Proxmox requirements, network prerequisites, storage requirements.
- [ ] Rewrite and complete `docs/checklist.md` — full pre-installation checklist for Proxmox, Packer, Terraform.
- [ ] Create `docs/architecture/index.md` — system architecture overview with mermaid diagram.
- [ ] Create `docs/architecture/networking.md` — vmbr0 external + labnet SDN, network CIDR config, DNS resolution chain.
- [ ] Create `docs/architecture/nomad-cluster.md` — 3-node Nomad cluster, GlusterFS, server discovery, VMID assignments.
- [ ] Create `docs/architecture/dns.md` — Pi-hole v6 + Unbound architecture, Gravity Sync, Pi-hole TOML config format, Samba AD DNS forwarding.
- [ ] Create `docs/architecture/pki.md` — step-ca internal PKI, ACME, how Traefik uses it, Proxmox TLS update.
- [ ] Create `docs/deployment/packer.md` — Packer golden image build process (build_docker, build_nomad), VMID assignments, how to run.
- [ ] Create `docs/deployment/terraform.md` — Terraform modules overview, how to configure tfvars, how to apply.
- [ ] Create `docs/deployment/setup.md` — Full `setup.sh` walkthrough, each menu option explained.
- [ ] Create `docs/services/traefik.md` — Traefik Nomad job, ACME config, service discovery, router rules.
- [ ] Create `docs/services/vault.md` — Vault Nomad job, initialization, unseal, WIF integration, credential file.
- [ ] Create `docs/services/authentik.md` — Authentik Nomad job, Vault secret integration, SSO capabilities.
- [ ] Create `docs/services/samba-ad.md` — Samba AD Nomad job, DC01/DC02, domain provisioning, DNS forwarding.
- [ ] Create `docs/services/kasm.md` — Kasm Workspaces VM deployment.
- [ ] Create `docs/troubleshooting/vault.md` — Vault-specific troubleshooting from CLAUDE.md.
- [ ] Create `docs/troubleshooting/traefik.md` — Traefik-specific troubleshooting from CLAUDE.md.
- [ ] Create `docs/troubleshooting/dns.md` — DNS-specific troubleshooting from CLAUDE.md.
- [ ] Create `docs/troubleshooting/samba-ad.md` — Samba AD troubleshooting from CLAUDE.md.
- [ ] Update `mkdocs.yml` nav to include all new pages in the correct hierarchy.
- [ ] Review all pages for cross-link accuracy and remove any remaining legacy references.

## Contract Version
Created: 2026-03-01
Author: worktree-contract-architect agent
Approved by: Jake (confirmed)
