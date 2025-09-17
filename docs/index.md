# Proxmox Lab

Infrastructure-as-Code (IaC) to build a reproducible home/lab environment on Proxmox VE. Automates golden images, VM/LXC provisioning, and local documentation.

---

## Features

- Proxmox-first lab automation (API token based)
- Packer templates for golden images (VM/LXC)
- Terraform for declarative provisioning
- MkDocs (Material) docs site with Docker Compose
- Internal CA artifacts for lab services
- Pihole/Unbound/dnscrypt-proxy for secure DNS services
- Docker Swarm cluster for HA application testing

---

## Requirements

To use this repo effectively, you'll need:

- **Docker & Docker Compose**
- **Proxmox VE** `>= 8.x` (API access enabled)
    - Proxmox API token with proper permissions

> Tip: Create a restricted API token on Proxmox (Datacenter → Permissions → API Tokens) and use it via environment variables rather than committing anything.  ￼

---

## Legal / License

This project is open source and distributed under the MIT License.

> This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. In no event shall the authors be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.

> 🔐 Do not commit secrets, credentials, or private keys. Use `.gitignore` and Vaults.

---

## Support This Project

If you find this project useful and want to support future development:

- [Buy me a coffee ☕](https://buymeacoffee.com/jstauffer)
- [Sponsor me on GitHub 💖](https://github.com/sponsors/jknyght9)
- Share the repo and give a ⭐ if you like it!

---

## Related Projects

### IaC

- [Packer](https://developer.hashicorp.com/packer)
- [Terraform](https://www.terraform.io/)

### DNS

- [PiHole](https://pi-hole.net/)
- [Unbound](https://github.com/NLnetLabs/unbound)
- [DNSCrypt-Proxy](https://github.com/DNSCrypt/dnscrypt-proxy)

### Certificate Authorities

- [Step-CA](https://smallstep.com/)

### Virtualization

- [Proxmox VE](https://www.proxmox.com/)

### Containerization

- [Docker](https://www.docker.com/)
- [Portainer](https://www.portainer.io/)
