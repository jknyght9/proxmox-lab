# External Resources

Links to official documentation and community resources for the technologies used in Proxmox Lab.

---

## Virtualization

### Proxmox VE
- [Official Documentation](https://pve.proxmox.com/pve-docs/)
- [Wiki](https://pve.proxmox.com/wiki/Main_Page)
- [API Reference](https://pve.proxmox.com/pve-docs/api-viewer/)
- [Forum](https://forum.proxmox.com/)

---

## Infrastructure as Code

### Terraform
- [Official Documentation](https://developer.hashicorp.com/terraform/docs)
- [CLI Reference](https://developer.hashicorp.com/terraform/cli)
- [Language Reference (HCL)](https://developer.hashicorp.com/terraform/language)
- [bpg/proxmox Provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) -- the Terraform provider used by Proxmox Lab

### Packer
- [Official Documentation](https://developer.hashicorp.com/packer/docs)
- [Proxmox Plugin](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox)
- [HCL Templates](https://developer.hashicorp.com/packer/docs/templates/hcl_templates)

---

## Container Orchestration

### HashiCorp Nomad
- [Official Documentation](https://developer.hashicorp.com/nomad/docs)
- [Job Specification](https://developer.hashicorp.com/nomad/docs/job-specification)
- [CLI Reference](https://developer.hashicorp.com/nomad/docs/commands)
- [Service Discovery](https://developer.hashicorp.com/nomad/docs/networking/service-discovery)
- [Docker Driver](https://developer.hashicorp.com/nomad/docs/drivers/docker)
- [Vault Integration](https://developer.hashicorp.com/nomad/docs/integrations/vault-integration)
- [Workload Identity](https://developer.hashicorp.com/nomad/docs/concepts/workload-identity)

---

## Secrets Management

### HashiCorp Vault
- [Official Documentation](https://developer.hashicorp.com/vault/docs)
- [KV Secrets Engine v2](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)
- [JWT/OIDC Auth Method](https://developer.hashicorp.com/vault/docs/auth/jwt)
- [Policies](https://developer.hashicorp.com/vault/docs/concepts/policies)
- [API Reference](https://developer.hashicorp.com/vault/api-docs)
- [Seal/Unseal](https://developer.hashicorp.com/vault/docs/concepts/seal)

---

## Reverse Proxy

### Traefik
- [Official Documentation](https://doc.traefik.io/traefik/)
- [Nomad Provider](https://doc.traefik.io/traefik/providers/nomad/)
- [ACME (Let's Encrypt / Custom CA)](https://doc.traefik.io/traefik/https/acme/)
- [Routers](https://doc.traefik.io/traefik/routing/routers/)
- [Dashboard](https://doc.traefik.io/traefik/operations/dashboard/)

---

## DNS

### Pi-hole
- [Official Documentation](https://docs.pi-hole.net/)
- [Pi-hole v6 Release Notes](https://pi-hole.net/blog/2025/02/18/pi-hole-v6-is-here/)
- [FTLDNS Configuration](https://docs.pi-hole.net/ftldns/configfile/)
- [GitHub Repository](https://github.com/pi-hole/pi-hole)

### Unbound
- [Official Documentation](https://unbound.docs.nlnetlabs.nl/en/latest/)
- [Pi-hole + Unbound Guide](https://docs.pi-hole.net/guides/dns/unbound/)

---

## Certificate Authority

### step-ca (Smallstep)
- [Official Documentation](https://smallstep.com/docs/step-ca/)
- [ACME Server](https://smallstep.com/docs/step-ca/acme-basics/)
- [Getting Started](https://smallstep.com/docs/step-ca/getting-started/)
- [GitHub Repository](https://github.com/smallstep/certificates)

### acme.sh
- [Official Documentation](https://github.com/acmesh-official/acme.sh/wiki)
- [GitHub Repository](https://github.com/acmesh-official/acme.sh)

---

## Identity Provider

### Authentik
- [Official Documentation](https://docs.goauthentik.io/)
- [Installation](https://docs.goauthentik.io/docs/install-config/)
- [Providers (OAuth2, SAML, LDAP)](https://docs.goauthentik.io/docs/add-secure-apps/)
- [API Reference](https://docs.goauthentik.io/developer-docs/api/)
- [GitHub Repository](https://github.com/goauthentik/authentik)

---

## Active Directory

### Samba
- [Official Documentation](https://wiki.samba.org/index.php/Main_Page)
- [Setting up Samba as an AD Domain Controller](https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller)
- [Joining a Samba DC to an Existing AD](https://wiki.samba.org/index.php/Joining_a_Samba_DC_to_an_Existing_Active_Directory)
- [samba-tool Reference](https://wiki.samba.org/index.php/Samba-tool)

---

## Distributed Storage

### GlusterFS
- [Official Documentation](https://docs.gluster.org/en/latest/)
- [Architecture Overview](https://docs.gluster.org/en/latest/Quick-Start-Guide/Architecture/)
- [Volume Types](https://docs.gluster.org/en/latest/Administrator-Guide/Setting-Up-Volumes/)
- [Troubleshooting](https://docs.gluster.org/en/latest/Administrator-Guide/Troubleshooting/)

---

## Remote Desktop

### Kasm Workspaces
- [Official Documentation](https://kasmweb.com/docs/latest/)
- [Installation Guide](https://kasmweb.com/docs/latest/install.html)
- [Administrator Guide](https://kasmweb.com/docs/latest/guide/admin.html)

---

## Cloud-Init

- [Official Documentation](https://cloudinit.readthedocs.io/en/latest/)
- [Module Reference](https://cloudinit.readthedocs.io/en/latest/reference/modules.html)
- [Proxmox Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)

---

## Docker

### Docker Engine
- [Official Documentation](https://docs.docker.com/engine/)
- [Docker Compose](https://docs.docker.com/compose/)
- [Compose File Reference](https://docs.docker.com/compose/compose-file/)

---

## Utilities

### jq
- [Official Documentation](https://jqlang.github.io/jq/)
- [Manual](https://jqlang.github.io/jq/manual/)
- [Tutorial](https://jqlang.github.io/jq/tutorial/)

### sshpass
- [Manual Page](https://linux.die.net/man/1/sshpass)

---

## MkDocs (Documentation)

### MkDocs
- [Official Documentation](https://www.mkdocs.org/)

### Material for MkDocs
- [Official Documentation](https://squidfunk.github.io/mkdocs-material/)
- [Reference](https://squidfunk.github.io/mkdocs-material/reference/)
- [Admonitions](https://squidfunk.github.io/mkdocs-material/reference/admonitions/)
