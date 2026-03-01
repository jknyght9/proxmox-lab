# FAQ

Frequently asked questions about Proxmox Lab.

---

## General

### Can I run this on a single Proxmox node?

Yes. Proxmox Lab supports single-node deployments. During setup, configure `cluster-info.json` with a single Proxmox node. The Nomad cluster still deploys 3 VMs on the same node, and GlusterFS replicates across them. DNS can be deployed with a single Pi-hole instance. Samba AD will automatically deploy only DC01 if nomad02 does not exist.

Keep in mind that a single physical node means no hardware redundancy -- if the host goes down, all services go offline.

### Can I run this on a multi-node Proxmox cluster?

Yes. Proxmox Lab is designed to work with Proxmox clusters. Configure `proxmox_node_ips` in `terraform.tfvars` with all your cluster node names and IPs. VMs and LXCs will be distributed across nodes. Template storage must be on shared storage (e.g., Ceph, NFS) accessible from all nodes -- configure this with the `template_storage` variable.

### What hardware do I need?

Minimum recommended specs for a single node:

- **CPU**: 4 cores (8 threads recommended)
- **RAM**: 32 GB (16 GB minimum, but tight)
- **Storage**: 200 GB SSD

The Nomad cluster alone requires 3 VMs, each needing CPU and RAM. Pi-hole LXCs are lightweight. Kasm and Authentik add further resource requirements.

### Is this production-ready?

No. This project is designed as a **lab/learning environment**. While it follows many best practices, it makes trade-offs for simplicity:

- Vault uses a single unseal key (threshold 1)
- Nomad does not have ACLs enabled by default
- All services are pinned to a single node (nomad01)
- The Traefik dashboard has no authentication

Use this as a reference or starting point, but evaluate security requirements before deploying anything production-critical.

---

## Configuration

### How do I change the DNS domain?

The DNS domain is set by the `dns_postfix` variable in `terraform/terraform.tfvars`. To change it:

1. Update `dns_postfix` in `terraform/terraform.tfvars`
2. Redeploy infrastructure with Terraform (this recreates VMs/LXCs with the new domain)
3. Rebuild DNS records (setup.sh menu option 10)
4. Regenerate certificates if needed (the CA and all service certs reference the domain)

!!! warning
    Changing the domain after deployment requires redeploying most infrastructure. This is effectively a rebuild of the lab.

### How do I change the network CIDR?

Network ranges are configured during initial setup and stored in `cluster-info.json`. To change them:

1. Purge the existing deployment (setup.sh menu option 15)
2. Delete `cluster-info.json`
3. Run setup again with the new network configuration

Network changes cannot be applied incrementally -- a full redeploy is required.

### How do I change a VM's IP address?

VM IP addresses are assigned by Terraform based on the module configuration and network CIDR. To change an IP:

1. Update the relevant Terraform module variables
2. Destroy and recreate the affected VM: `docker compose run terraform destroy -target=<resource>`
3. Apply: `docker compose run terraform apply`
4. Rebuild DNS records if needed (setup.sh menu option 10)

### Where are the configuration files?

| File | Purpose |
|------|---------|
| `terraform/terraform.tfvars` | Terraform input variables |
| `packer/packer.auto.pkrvars.hcl` | Packer input variables |
| `cluster-info.json` | Cluster topology, network config (auto-generated) |
| `hosts.json` | Deployed host IPs (auto-generated) |
| `crypto/vault-credentials.json` | Vault unseal key and root token (auto-generated) |
| `compose.yml` | Docker Compose service definitions (Nomad address, etc.) |

---

## Services

### How do I add a new Nomad job?

To deploy a new service on Nomad:

1. Create a job file in `nomad/jobs/` (e.g., `myservice.nomad.hcl`)
2. Define the job with appropriate constraints, networking, and service discovery tags
3. If the service needs Vault secrets, create a Vault policy in `nomad/vault-policies/` and a Vault role
4. Deploy: `docker compose run --rm nomad job run /nomad/jobs/myservice.nomad.hcl`
5. Add a DNS record for the service in Pi-hole (or update the `updateDNSRecords` function)
6. If using Traefik, add Traefik tags to the Nomad service stanza for automatic routing

Use an existing job file (e.g., `vault.nomad.hcl`) as a template. Key considerations:

- Pin to nomad01 with a hostname constraint if the service needs a stable IP
- Use `privileged = true` if writing to GlusterFS
- Add both FQDN and short name host matching rules for Traefik

### What if Vault is sealed after a reboot?

Vault seals itself whenever the container restarts. After a node reboot:

1. Wait for Nomad to start and schedule the Vault job
2. Check that the Vault allocation is running:
   ```bash
   docker compose run --rm nomad job status vault
   ```
3. Unseal Vault using the key from `crypto/vault-credentials.json`:
   ```bash
   curl -X PUT http://<nomad01-ip>:8200/v1/sys/unseal \
     -d "{\"key\": \"$(cat crypto/vault-credentials.json | jq -r '.unseal_key')\"}"
   ```

Services that depend on Vault (Authentik, Samba AD) will fail until Vault is unsealed. They may need to be restarted after unsealing:

```bash
docker compose run --rm nomad job stop authentik
docker compose run --rm nomad job run /nomad/jobs/authentik.nomad.hcl
```

See [Backup & Recovery - Vault Unseal](../operations/backup-recovery.md#vault-unseal-after-restart) for more details.

### How do I update a Nomad job?

To update a running job (e.g., change the Docker image version):

1. Edit the job file in `nomad/jobs/`
2. Plan the change to see what will happen:
   ```bash
   docker compose run --rm nomad job plan /nomad/jobs/<job-file>
   ```
3. Apply the change:
   ```bash
   docker compose run --rm nomad job run /nomad/jobs/<job-file>
   ```

Nomad performs a rolling update by default, stopping the old allocation and starting a new one.

### Why are all services pinned to nomad01?

All service jobs constrain to `nomad01` for several reasons:

- **Consistent DNS**: all service DNS records point to a single IP (nomad01)
- **ACME challenges**: Traefik must receive HTTP-01 challenge requests on the node where DNS points
- **Simplicity**: no cross-node routing, load balancing, or service mesh required
- **Port conflicts**: services use well-known ports (80, 443, 8200) that can only bind once per node

This is a deliberate trade-off of high availability for simplicity in a lab environment.

### How do I access Nomad service logs?

```bash
# View logs for the latest allocation
docker compose run --rm nomad alloc logs -job <job-name>

# View stderr
docker compose run --rm nomad alloc logs -job <job-name> -stderr

# Follow in real time
docker compose run --rm nomad alloc logs -job <job-name> -f
```

You can also view logs in the Nomad UI at `http://<nomad01-ip>:4646` by navigating to the job, then the allocation, then the task.

---

## DNS

### How do I add a custom DNS record?

The simplest method is to add it directly on the primary Pi-hole (dns-01):

```bash
# Read current records
ssh root@<dns-01-ip> "pihole-FTL --config dns.hosts"

# Add your record (include ALL existing records plus the new one)
ssh root@<dns-01-ip> "pihole-FTL --config dns.hosts '[\"192.168.1.50 vault.mylab.lan\", \"192.168.1.60 myservice.mylab.lan\"]'"
```

The change will replicate to other Pi-hole instances via nebula-sync within 5 minutes.

See [DNS Management](../operations/dns-management.md) for detailed instructions.

### Why can I not resolve external domains?

If Pi-hole cannot resolve external domains:

1. Check that Unbound is running on the Pi-hole LXC:
   ```bash
   ssh root@<dns-ip> "systemctl status unbound"
   ```
2. Verify upstream DNS is configured:
   ```bash
   ssh root@<dns-ip> "pihole-FTL --config dns.upstreams"
   ```
3. Test Unbound directly:
   ```bash
   ssh root@<dns-ip> "dig @127.0.0.1 -p 5335 google.com"
   ```

---

## Certificates

### How do I trust the lab CA on my workstation?

See [Certificate Operations - Installing the Root CA on Workstations](../operations/certificate-operations.md#installing-the-root-ca-on-workstations) for platform-specific instructions.

The root CA certificate is at `crypto/root_ca.crt`.

### Why does my browser show a certificate warning?

Your browser does not trust the lab's internal CA by default. You need to install the root CA certificate in your operating system's trust store (and Firefox's trust store, since Firefox uses its own). See the instructions linked above.

### How do I renew an expired certificate?

For node certificates managed by acme.sh, renewal is automatic. To force renewal:

```bash
ssh user@<node-ip> "acme.sh --renew -d <hostname>.<domain> --force"
```

For Traefik-managed service certificates, they renew automatically. If they are stuck, clear the ACME store:

```bash
ssh user@<nomad01-ip> "sudo rm /srv/gluster/nomad-data/traefik/acme.json"
docker compose run --rm nomad job stop -purge traefik
docker compose run --rm nomad job run /nomad/jobs/traefik.nomad.hcl
```

---

## Troubleshooting

### Setup.sh fails partway through. What do I do?

The setup script is designed to be re-runnable. You can safely run it again, selecting the same menu option. If a specific step continues to fail:

1. Check the error message for clues (network, SSH, API, etc.)
2. Try deploying the failing component individually (e.g., menu option 5 for Nomad only)
3. Check [Common Issues](common-issues.md) for known problems
4. Use [Diagnostic Commands](diagnostic-commands.md) to verify prerequisites

### How do I reset everything and start over?

Use setup.sh menu option 15 (Full Purge):

```bash
./setup.sh
# Select option 15: Purge entire deployment
# Type PURGE to confirm
```

This removes all VMs, LXCs, and templates. Then run setup again from scratch.

### Docker Compose commands fail with connection errors

If `docker compose run --rm nomad` fails to connect to Nomad:

1. Verify the `NOMAD_ADDR` in `compose.yml` matches your nomad01 IP
2. Check that nomad01 is running and the Nomad API (port 4646) is accessible
3. Test connectivity: `nc -zv <nomad01-ip> 4646`

### Can I use this with Proxmox VE 8?

Yes. Proxmox Lab requires Proxmox VE 7.x or later. It has been tested with Proxmox VE 7.x and 8.x.
