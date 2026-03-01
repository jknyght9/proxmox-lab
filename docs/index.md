# Proxmox Lab

Infrastructure-as-Code (IaC) to build a reproducible home/lab environment on Proxmox VE. Automates golden images, VM/LXC provisioning, internal certificate authority, and secure DNS services.

---

## Quick Navigation

<div class="grid cards" markdown>

-   :material-rocket-launch: **Getting Started**

    ---

    New to Proxmox Lab? Start here for installation and setup.

    [:octicons-arrow-right-24: Introduction](getting-started/introduction.md)

-   :material-sitemap: **Architecture**

    ---

    Understand the system design, network topology, and service relationships.

    [:octicons-arrow-right-24: Architecture Overview](architecture/overview.md)

-   :material-cog: **Configuration**

    ---

    Reference documentation for Terraform and Packer variables.

    [:octicons-arrow-right-24: Configuration Reference](configuration/terraform-variables.md)

-   :material-wrench: **Operations**

    ---

    Day-to-day operations: accessing services, managing DNS, issuing certificates.

    [:octicons-arrow-right-24: Operations Guide](operations/accessing-services.md)

</div>

---

## What You'll Build

This project deploys a complete lab infrastructure on Proxmox VE:

| Component | Type | Purpose |
|-----------|------|---------|
| **Nomad Cluster** | 3 VMs | HashiCorp Nomad orchestration with GlusterFS |
| **Vault** | Nomad Job | Secrets management with Workload Identity |
| **Authentik** | Nomad Job | SSO and identity provider (OAuth2/OIDC/SAML) |
| **Traefik** | Nomad Job | Reverse proxy and load balancer |
| **Kasm Workspaces** | 1 VM | Browser-based remote desktops |
| **Pihole (Main)** | LXC | DNS + ad-blocking for your network |
| **Pihole (Labnet)** | LXC | DNS for isolated SDN network |
| **Step-CA** | LXC | Internal Certificate Authority with ACME |

---

## Features

- **Proxmox-first** automation using API tokens
- **Packer** templates for golden VM images
- **Terraform** for declarative infrastructure provisioning
- **HashiCorp Nomad** for container orchestration (3-node cluster)
- **HashiCorp Vault** with Workload Identity Federation for secrets
- **Authentik SSO** for unified authentication across services
- **Traefik** reverse proxy with automatic TLS via step-ca
- **Internal CA** with ACME protocol for automated TLS certificates
- **Secure DNS** with Pi-hole v6, Unbound, and Gravity Sync
- **GlusterFS** replicated storage for high availability
- **Dual network** architecture (external + isolated lab SDN)

---

## Requirements

!!! info "Prerequisites"
    - **Docker & Docker Compose** on your workstation
    - **Proxmox VE 8.x** or later with API access enabled
    - Network connectivity to your Proxmox server

[:octicons-arrow-right-24: Full prerequisites](getting-started/prerequisites.md)

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/jknyght9/proxmox-lab.git
cd proxmox-lab

# Run the automated setup
./setup.sh <PROXMOX_IP> <PROXMOX_PASSWORD>
```

[:octicons-arrow-right-24: Detailed quick start guide](getting-started/quick-start.md)

---

## License

This project is open source under the MIT License.

!!! warning "Security Notice"
    Never commit secrets, credentials, or private keys. Use `.gitignore` and secure vaults.

---

## Support This Project

If you find this project useful:

- [Buy me a coffee](https://buymeacoffee.com/jstauffer)
- [Sponsor on GitHub](https://github.com/sponsors/jknyght9)
- Star the repo on GitHub
