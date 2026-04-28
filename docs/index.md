# Proxmox Lab

Proxmox Lab is an Infrastructure-as-Code project for building a self-hosted home lab on Proxmox VE. It uses **Packer** for golden image creation and **Terraform** for infrastructure provisioning and service configuration, with a fully automated deployment driven by a single interactive menu.

## What it deploys

**Core infrastructure (always deployed):**

- 3-node HashiCorp Nomad cluster with GlusterFS shared storage
- Pi-hole v6 DNS cluster with Unbound (DNS-over-TLS), one node per Proxmox node
- HashiCorp Vault for secrets management and internal PKI (certificate authority)
- Traefik reverse proxy with wildcard TLS certificates from Vault PKI

**Optional services (menu-driven):**

- Authentik — SSO/identity provider (OAuth2, OIDC, SAML, LDAP proxy)
- Samba Active Directory — domain controllers for Windows domain joins
- LDAP Account Manager (LAM) — web UI for managing AD users and groups
- Kasm Workspaces — browser-based remote desktop / virtual desktop infrastructure
- Netbox — infrastructure inventory (auto-populated, UniFi integration)
- Uptime Kuma — service health monitoring dashboard
- Tailscale — subnet router for remote access to lab resources

## Architecture in brief

The project uses a **two-layer Terraform architecture**. Layer 1 (`terraform/`) provisions infrastructure: Nomad VMs, Pi-hole LXC containers, and Kasm. Layer 2 (`terraform/services/`) configures services running on that infrastructure: Vault PKI, JWT auth, Nomad job deployments, Authentik applications, DNS records, and NAS domain joins. Vault is the single source of truth for secrets; Nomad workloads authenticate to Vault using Workload Identity Federation (JWT) rather than long-lived tokens.

## Quick start

```bash
# 1. Copy and configure bootstrap.yml
cp bootstrap.yml.example bootstrap.yml
$EDITOR bootstrap.yml   # set Proxmox IP, root password, network CIDR, DNS suffix

# 2. Run the setup menu
./setup.sh

# 3. Select option 1 — full deployment (20-30 minutes)
```

See [Bootstrap Configuration](getting-started/bootstrap.md) for a complete explanation of every `bootstrap.yml` option, and [First Deploy](getting-started/first-deploy.md) for a walkthrough of what happens during option 1.

## Requirements

- Docker and Docker Compose (all tools run in containers)
- `sshpass`, `jq`, `yq` installed locally
- Proxmox VE 7.x or 8.x with at least one node
- A network bridge configured on Proxmox (auto-detected)

See [Prerequisites](getting-started/prerequisites.md) for full details.

## Navigation

| Section | What you will find |
|---------|-----------------|
| [Getting Started](getting-started/prerequisites.md) | Requirements, bootstrap.yml guide, first deployment walkthrough |
| [Architecture](architecture/overview.md) | 2-layer design, networking, secrets management |
| [Services](services/vault.md) | Per-service documentation for Vault, Traefik, Authentik, and more |
| [Tutorials](tutorials/ha-configuration.md) | Step-by-step guides for common tasks |
| [Operations](operations/menu-reference.md) | Menu reference, rollback, purge procedures |
| [Developer Guide](developer/adding-services.md) | Adding new Nomad services |
