# Dependency Manifest

All software packages and container images used in this project with their
pinned versions. Updated: April 2026.

## Terraform Providers

| Provider | Version | Constraint | Notes |
|----------|---------|------------|-------|
| bpg/proxmox | 0.104.x | `~> 0.104` | Proxmox VE API. Requires PVE 9.1+ |
| hashicorp/vault | 4.x | `~> 4.0` | Vault KV, PKI, JWT auth. v5.x is a major rewrite |
| hashicorp/nomad | 2.6.x | `~> 2.6.0` | Nomad job management |
| hashicorp/local | latest | implicit | Local file operations |
| hashicorp/null | latest | implicit | Null resources for provisioners |
| hashicorp/random | latest | implicit | Random password generation |

## Docker Images — Nomad Services

| Service | Image | Tag | Purpose |
|---------|-------|-----|---------|
| Vault | hashicorp/vault | 1.21.4 | Secrets management |
| Traefik | traefik | v3.6.14 | Reverse proxy, TLS termination |
| Authentik Server | ghcr.io/goauthentik/server | 2026.2.2 | SSO / Identity provider |
| Authentik LDAP | ghcr.io/goauthentik/ldap | 2026.2.2 | LDAP outpost (disabled) |
| Samba AD DC | ghcr.io/jknyght9/samba-ad-dc | latest | Active Directory DCs |
| PostgreSQL (Authentik) | postgres | 17 | Authentik database |
| PostgreSQL (Netbox) | postgres | 17 | Netbox database |
| Redis (Netbox) | redis | 8-alpine | Netbox cache/queue |
| Netbox | netboxcommunity/netbox | v4.5.8 | Inventory management |
| Uptime Kuma | louislam/uptime-kuma | 2.2.1 | Service monitoring |
| LAM | ghcr.io/ldapaccountmanager/lam | 9.5.2 | LDAP Account Manager |
| Tailscale | tailscale/tailscale | v1.92.4 | VPN subnet router |
| Docs (nginx) | nginx | stable-alpine | Documentation wiki |
| Backup | ubuntu | 24.04 | Backup job runner |

## Docker Images — Development (compose.yml)

| Service | Image | Tag | Purpose |
|---------|-------|-----|---------|
| Terraform | hashicorp/terraform | 1.14 | Infrastructure provisioning |
| Terraform (Layer 2) | hashicorp/terraform | 1.14 | Service configuration |
| Nomad CLI | hashicorp/nomad | 1.10 | Nomad job management |
| Packer | hashicorp/packer | custom build | VM template creation |
| MkDocs | squidfunk/mkdocs-material | 9.7.6 | Documentation build |

## Packer Base Images

| Template | VMID | Base Image | Purpose |
|----------|------|------------|---------|
| Ubuntu 24.04 | 9999 | Ubuntu Server 24.04 cloud image | Base template (parent of all clones used by deployAll) |
| Debian 12 | 9997 | Debian 12 Bookworm cloud image | Available to other projects via `packer build -only='base-debian.*' .` |
| Fedora Cloud 42 | 9998 | Fedora Cloud 42 cloud image | Available to other projects via `packer build -only='base-fedora.*' .` |
| Docker | 9001 | Clone of 9999 + Docker + GlusterFS | Docker workloads |
| Nomad | 9002 | Clone of 9999 + Nomad + Consul | Nomad cluster nodes |

## Infrastructure

| Component | Version | Notes |
|-----------|---------|-------|
| Proxmox VE | 9.x | Cluster with 3+ nodes |
| Nomad | 1.10.x | 3-node cluster (server + client) |
| Vault | 1.21.4 | Single instance on nomad01 |
| GlusterFS | 11.x | 3-node replicated volume |
| Pi-hole | v6.6+ | LXC containers, uses FTL engine |
| Unbound | 1.x | DNS-over-TLS upstream resolver |

## Version Update Policy

- **Terraform providers**: Pin to minor version (`~> X.Y`). Review changelogs before major bumps.
- **Docker images**: Pin to specific patch version. Avoid `latest`, `stable`, or major-only tags.
- **Packer base images**: Use latest LTS cloud images. Rebuild templates after OS updates.
- **Samba AD DC**: Uses `latest` tag (no version tags available). Consider pinning to digest for reproducibility.

## Updating Versions

1. Update the version in the relevant template or `providers.tf`
2. For Terraform providers: delete `.terraform.lock.hcl` and run `terraform init -upgrade`
3. For Docker images: the new image pulls automatically on next Nomad job deploy
4. For PostgreSQL major version upgrades: requires `pg_dump` / `pg_restore` migration
5. Test in a non-production environment before applying to the lab
