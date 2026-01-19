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
| **Docker Swarm** | 3 VMs | Container orchestration cluster |
| **Kasm Workspaces** | 1 VM | Browser-based remote desktops |
| **Pihole (External)** | LXC | DNS + ad-blocking for your network |
| **Pihole (Internal)** | LXC | DNS + DHCP for isolated lab network |
| **Step-CA** | LXC | Internal Certificate Authority with ACME |

---

## Features

- **Proxmox-first** automation using API tokens
- **Packer** templates for golden VM/LXC images
- **Terraform** for declarative infrastructure provisioning
- **Internal CA** with ACME protocol for automated TLS certificates
- **Secure DNS** with Pihole, Unbound, and dnscrypt-proxy
- **Docker Swarm** cluster for high-availability container testing
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
