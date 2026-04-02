# Proxmox Lab

Infrastructure-as-Code (IaC) to build a reproducible home/lab environment on Proxmox VE. Automates golden images, VM/LXC provisioning, container orchestration, secrets management, internal certificate authority, and secure DNS services.

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

-   :material-cube-outline: **Modules**

    ---

    Terraform modules for Nomad, Kasm, Pi-hole, and Step-CA.

    [:octicons-arrow-right-24: Nomad Cluster](modules/nomad-cluster.md)

-   :material-server-network: **Services**

    ---

    Nomad-managed services: Traefik, Vault, Authentik, and Samba AD.

    [:octicons-arrow-right-24: Services](services/traefik.md)

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
| **Nomad Cluster** | 3 VMs (905-907) | Container orchestration with HashiCorp Nomad |
| **Kasm Workspaces** | 1 VM (930) | Browser-based remote desktops |
| **Pi-hole DNS** | 1-3 LXCs (910-912) | DNS + ad-blocking with Unbound DNS-over-TLS |
| **Pi-hole Labnet** | 0-2 LXCs (920-921) | DNS for isolated SDN network |
| **Step-CA** | 1 LXC (902) | Internal Certificate Authority with ACME |

### Nomad Services

Deployed as Nomad jobs on the cluster:

| Service | Purpose |
|---------|---------|
| **Traefik** | Reverse proxy / load balancer with automatic TLS |
| **Vault** | Secrets management with Workload Identity Federation |
| **Authentik** | SSO / Identity provider (OAuth2, OIDC, SAML, LDAP) |
| **Samba AD** | Active Directory Domain Controllers |

---

## Features

- **Proxmox-first** automation using API tokens
- **Packer** templates for golden VM images
- **Terraform** for declarative infrastructure provisioning
- **Internal CA** with ACME protocol for automated TLS certificates
- **Secure DNS** with Pi-hole v6 and Unbound (DNS-over-TLS)
- **HashiCorp Nomad** cluster for container orchestration
- **HashiCorp Vault** for secrets management with Workload Identity Federation
- **Authentik SSO** for centralized identity management
- **Dual network** architecture (external + isolated lab SDN)
- **GlusterFS** distributed storage across Nomad nodes

---

## Requirements

!!! info "Prerequisites"
    - **Docker & Docker Compose** on your workstation
    - **Proxmox VE 7.x** or later with API access enabled
    - **sshpass** and **jq** installed locally
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
