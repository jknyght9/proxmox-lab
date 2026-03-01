# Glossary

Key terms and concepts used throughout Proxmox Lab documentation.

---

## A

### ACME (Automatic Certificate Management Environment)
A protocol for automating certificate issuance and renewal. Proxmox Lab uses ACME via step-ca (as the CA) and acme.sh/Traefik (as clients) to automate TLS certificate management across the lab.

### acme.sh
A lightweight ACME client written in shell script. Installed on Nomad and Kasm nodes during Packer template builds to request and renew TLS certificates from step-ca.

### Allocation (Nomad)
A mapping between a Nomad job's task group and a client node. When Nomad schedules a job, it creates an allocation on a specific node to run the tasks. Each allocation has a unique ID and lifecycle (pending, running, complete, failed).

### Authentik
An open-source identity provider supporting OAuth2, OpenID Connect, SAML, and LDAP. Deployed as a Nomad job in Proxmox Lab to provide single sign-on (SSO) and centralized user management.

---

## C

### Cloud-Init
An industry-standard tool for automating the initialization of cloud instances. Proxmox Lab uses cloud-init templates to configure hostnames, SSH keys, networking, and service-specific settings on first boot.

### Constraint (Nomad)
A rule in a Nomad job definition that restricts which nodes can run the job. Proxmox Lab pins all service jobs to `nomad01` using a hostname constraint.

---

## D

### Datacenter (Nomad)
A logical grouping of Nomad nodes. Proxmox Lab uses a single datacenter called `dc1`.

### DNS-over-TLS (DoT)
A protocol for encrypting DNS queries using TLS. Unbound on Pi-hole LXCs uses DNS-over-TLS to forward queries to upstream resolvers (Cloudflare, Quad9), preventing eavesdropping on DNS traffic.

### DNS Postfix
The domain suffix used throughout the lab (e.g., `jdclabs.lan`). Configured via the `dns_postfix` variable in `terraform.tfvars`. All service hostnames use this as their domain.

---

## F

### FTL (Faster Than Light)
Pi-hole's DNS engine in v6. FTL handles DNS resolution, ad blocking, and local DNS record management. Configuration is done through `/etc/pihole/pihole.toml` or the `pihole-FTL` command.

---

## G

### GlusterFS
A scalable distributed filesystem. Proxmox Lab uses GlusterFS across the 3-node Nomad cluster to provide a replicated volume (`/srv/gluster/nomad-data`) for persistent service data (Vault, Traefik, Authentik, Samba AD).

### Golden Image
A pre-configured VM template created by Packer. Proxmox Lab builds two golden images: a Docker base template (VMID 9001) and a Nomad template (VMID 9002). These serve as the foundation for all deployed VMs.

### Gravity Sync
A mechanism for replicating Pi-hole configuration across multiple instances. In Proxmox Lab, nebula-sync handles this replication every 5 minutes from the primary Pi-hole (dns-01) to secondary instances.

---

## H

### HCL (HashiCorp Configuration Language)
A declarative configuration language used by Terraform, Packer, Nomad, and Vault. All infrastructure definitions in Proxmox Lab are written in HCL.

---

## I

### Infrastructure as Code (IaC)
The practice of managing infrastructure through machine-readable configuration files rather than manual processes. Proxmox Lab uses Packer for image creation and Terraform for provisioning, making the entire lab reproducible.

---

## J

### JWT (JSON Web Token)
A compact token format used for securely transmitting information between parties. Nomad uses JWTs for Workload Identity Federation with Vault, allowing jobs to authenticate without storing long-lived tokens.

### JWKS (JSON Web Key Set)
A set of public keys used to verify JWT signatures. Vault's `jwt-nomad` auth backend fetches the JWKS from Nomad to validate workload identity tokens.

---

## K

### Kasm Workspaces
A platform for browser-based remote desktops and applications. Deployed as a standalone VM (VMID 930) in Proxmox Lab, providing secure remote access to desktop environments.

---

## L

### Labnet
The isolated SDN (Software-Defined Network) in Proxmox Lab. Labnet provides a separate internal network for services that should not be directly accessible from the external network. Labnet DNS instances serve this network.

### LXC (Linux Container)
A lightweight virtualization technology used by Proxmox for running containerized workloads. Pi-hole and step-ca run in LXC containers, which are more resource-efficient than full VMs.

---

## N

### nebula-sync
The synchronization tool used to replicate Pi-hole configuration from the primary instance to secondary instances. Runs every 5 minutes.

### Nomad
A HashiCorp workload orchestrator for deploying containers, VMs, and standalone applications. Proxmox Lab runs a 3-node Nomad cluster where each node serves as both server and client. Nomad manages Traefik, Vault, Authentik, and Samba AD.

---

## P

### Packer
A HashiCorp tool for creating identical machine images for multiple platforms. Proxmox Lab uses Packer to build golden VM templates on Proxmox with Docker, Nomad, and other prerequisites pre-installed.

### Pi-hole
A network-level DNS sinkhole for ad blocking. Proxmox Lab deploys Pi-hole v6 in LXC containers, using it for both ad blocking and local DNS resolution. Runs Unbound as a recursive resolver with DNS-over-TLS.

### PKI (Public Key Infrastructure)
A framework for managing digital certificates and encryption keys. Proxmox Lab implements an internal PKI using step-ca as the root Certificate Authority.

### Proxmox VE (Virtual Environment)
An open-source server virtualization platform based on KVM and LXC. Proxmox Lab automates infrastructure deployment on Proxmox VE through its API.

---

## Q

### Quorum
The minimum number of servers that must be available for the cluster to function. A 3-node Nomad cluster requires 2 nodes (a majority) to maintain quorum and continue operating.

---

## R

### Raft
A consensus algorithm used by Nomad (and Vault) to replicate state across server nodes. Raft ensures that all servers agree on the current state, even if some nodes fail.

### Region (Nomad)
A logical grouping of datacenters. Proxmox Lab uses a single region called `global`.

---

## S

### Samba AD
Samba Active Directory, an open-source implementation of Microsoft's Active Directory. Deployed as Nomad jobs in Proxmox Lab, providing AD Domain Controllers for centralized authentication and directory services.

### SDN (Software-Defined Networking)
Proxmox VE's built-in virtual networking. Proxmox Lab uses SDN to create the `labnet` isolated internal network, separate from the external `vmbr0` bridge.

### Shamir's Secret Sharing
A cryptographic method for splitting a secret into multiple shares. Vault uses this for its unseal key. Proxmox Lab configures Vault with a single share and threshold of 1, meaning only one key is needed to unseal.

### step-ca
An open-source online Certificate Authority by Smallstep. Deployed in an LXC container (VMID 902), step-ca provides the root CA for the lab and supports the ACME protocol for automated certificate issuance.

---

## T

### Terraform
A HashiCorp Infrastructure as Code tool for provisioning and managing cloud and on-premises resources. Proxmox Lab uses Terraform with the bpg/proxmox provider to create VMs and LXC containers on Proxmox VE.

### TOML (Tom's Obvious Minimal Language)
A configuration file format. Pi-hole v6 uses TOML for its configuration file (`/etc/pihole/pihole.toml`).

### Traefik
A modern reverse proxy and load balancer. Deployed as a Nomad job, Traefik discovers services through Nomad's service catalog and automatically routes traffic to them. It manages TLS certificates via the step-ca ACME resolver.

---

## U

### Unbound
A validating, recursive DNS resolver. Runs alongside Pi-hole on each LXC to provide DNS-over-TLS forwarding to upstream resolvers (Cloudflare and Quad9).

### Unseal (Vault)
The process of providing the unseal key to Vault so it can decrypt its storage backend and begin serving requests. Vault seals itself on every restart, requiring manual (or automated) unsealing.

---

## V

### Vault
A HashiCorp tool for secrets management, encryption, and identity. Deployed as a Nomad job in Proxmox Lab, Vault stores secrets for Authentik and Samba AD, using Workload Identity Federation for authentication.

### VMID
A unique numeric identifier for VMs and LXC containers in Proxmox. Proxmox Lab uses a structured VMID scheme (see [Architecture Overview](../architecture/overview.md) for the full mapping).

---

## W

### WIF (Workload Identity Federation)
A method for workloads to authenticate to external services using short-lived, cryptographically signed tokens instead of long-lived credentials. Nomad signs JWTs for each job allocation, and Vault validates them via the `jwt-nomad` auth backend. This eliminates the need to store Vault tokens on Nomad nodes.
