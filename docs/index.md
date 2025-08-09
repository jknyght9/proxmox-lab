# Proxmox Lab

This project uses Infrastructure as Code (IaC) to build lab infrastructure for testing, development, and deployment of enterprise services.

---

## Description

This project is designed to:

- Automate infrastructure deployments
- Experiment with cloud-native tools in a self-hosted environment
- Document everything for reproducibility and learning
- Support hybrid (bare metal + cloud) configurations

You’ll find:

- ✅ Infrastructure as Code (IaC)
- 📄 MkDocs-powered documentation
- 🐧 Linux-first setup (but cross-platform where possible)
- 🔐 Security- and privacy-aware tooling

---

## Requirements

To use this repo effectively, you'll need:

- **Docker & Docker Compose**
- **Proxmox VE** `>= 8.x` (API access enabled)

---

## Documentation

This documentation is inside the [`/docs`](./docs) folder and built using [MkDocs Material](https://squidfunk.github.io/mkdocs-material/).

To serve locally:
```bash
docker compose up mkdocs
```

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

### IaC and Documentation

- [Packer](https://developer.hashicorp.com/packer)
- [Terraform](https://www.terraform.io/)
- [MkDocs](https://www.mkdocs.org/)

### DNS

- [PiHole](https://pi-hole.net/)
- [Unbound](https://github.com/NLnetLabs/unbound)

### Certificate Authorities

- [Step-CA](https://smallstep.com/)

### Virtualization

- [Proxmox VE](https://www.proxmox.com/)
