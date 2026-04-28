# Rollback and Purge

This page describes the three levels of rollback available and what each one destroys.

## Layer 2 Rollback (Services Only)

**Menu option:** 7) Rollback services

Destroys all service configuration while keeping the infrastructure (VMs, LXC containers) intact.

### What is destroyed

- All Layer 2 Nomad jobs: Traefik, Authentik, Samba AD, Uptime Kuma, LAM, Netbox, backup, Tailscale
- Vault PKI (root CA, intermediate CA)
- Vault JWT auth backend and all roles
- Vault policies
- Vault KV secrets (all generated passwords)
- DNS records from Pi-hole (service hostnames)
- Authentik applications and providers
- TLS certificates (Traefik wildcard, Vault listener)

### What survives

- Nomad cluster VMs (nomad01, nomad02, nomad03)
- Pi-hole LXC containers (dns-01, dns-02, dns-03)
- Kasm VM (if deployed)
- GlusterFS volumes and data (but services that wrote to them are no longer running)

### After rollback

DNS on Nomad VMs and Proxmox nodes is reset to the gateway IP (since Pi-hole is no longer configured with the correct records).

To redeploy services:
```bash
./setup.sh --dev
# d5) Deploy services (Traefik, Authentik, secrets)
```

Or re-run the full deployment starting from Phase 4:
```bash
./setup.sh
# 1) Deploy all services
# (Phases 1-2 are skipped since templates and VMs exist)
```

### Confirmation

The rollback prompts for confirmation: `Are you sure? [y/N]`

## Layer 1 Rollback (Infrastructure + Services)

**Menu option:** 8) Rollback infrastructure

Destroys all VMs and LXC containers. Also runs a Layer 2 rollback first for a clean shutdown.

### What is destroyed

Everything from Layer 2 rollback, plus:

- All Nomad VMs (nomad01, nomad02, nomad03)
- All Pi-hole LXC containers (dns-01, dns-02, dns-03)
- Kasm VM (if deployed)
- **GlusterFS data** — all service data (Vault, Authentik DB, Samba AD, Netbox, etc.)
- Generated config files: `terraform/services/terraform.tfvars`, `hosts.json`, `crypto/vault-credentials.json`

### What survives

- Proxmox nodes (obviously)
- Packer templates (9999, 9001, 9002) — preserved by default, optionally removed
- `bootstrap.yml`
- `terraform/terraform.tfvars` (but the Vault token/addresses in it are invalid)

!!! danger "GlusterFS data is on VM disks"
    GlusterFS data lives on VM local disks, not on NFS or shared storage. Destroying the VMs permanently destroys all service data. If you need to preserve data, back it up before rollback:
    ```bash
    ssh labadmin@nomad01 "sudo tar -czf /tmp/vault-backup.tar.gz /srv/gluster/nomad-data/vault"
    scp labadmin@nomad01:/tmp/vault-backup.tar.gz ./
    ```

### After rollback

To redeploy from scratch:
```bash
./setup.sh
# 1) Deploy all services
# Phase 1 (templates) skipped if 9001/9002 exist
# Phase 2 (VMs) deploys fresh VMs
# Phase 3 (Vault) initializes fresh Vault
```

### Confirmation

Requires typing `DESTROY` (uppercase) to confirm.

## Full Purge

**Menu option:** 9) Purge entire deployment

Resets the entire Proxmox environment to pre-install state. Used when you want a clean start or when Terraform state is too inconsistent to use `destroy`.

### What is destroyed

Everything from Layer 1 rollback, plus:

- Packer templates (VMIDs 9999, 9001, 9002)
- Cloud-init snippets from Proxmox storage
- `hashicorp@pam` Proxmox API user
- `HashicorpBuild` Proxmox role
- DNS configuration reset to gateway on all Proxmox nodes
- `terraform.tfvars`, `cluster-info.json`, `hosts.json`
- `crypto/` directory (SSH keys, API credentials, Vault credentials)

### Purge method

Unlike rollback (which uses `terraform destroy`), purge uses direct Proxmox API and SSH calls:
- `qm destroy <vmid>` for VMs
- `pct destroy <vmid>` for LXC containers
- Proxmox API calls to remove snippets and users

This is more robust than Terraform destroy because it works even when Terraform state is inconsistent or when resources were created outside Terraform.

### After purge

The project directory is restored to a near-pristine state (only `bootstrap.yml` and project code remain). Re-run from scratch:

```bash
./setup.sh
# 1) Deploy all services
# All phases run fresh
```

### Confirmation

Multiple confirmation prompts. Requires explicit confirmation at each stage.

## Manual Recovery Commands

If automated rollback fails (e.g., Nomad is unreachable), use these manual commands:

### Stop Nomad jobs directly

```bash
ssh labadmin@nomad01 <<'EOF'
for job in traefik authentik samba-ad uptime-kuma lam netbox backup tailscale; do
  nomad job stop -purge $job 2>/dev/null || true
done
EOF
```

### Remove VMs via Proxmox API

```bash
# Via SSH to Proxmox node
ssh root@<proxmox-ip> "qm stop 905; qm destroy 905"
ssh root@<proxmox-ip> "qm stop 906; qm destroy 906"
# etc.
```

### Reset DNS on Proxmox nodes

```bash
ssh root@<proxmox-ip> "pvesh set /nodes/<nodename>/dns -dns1 <gateway-ip>"
```

### Clean generated files

```bash
rm -f terraform/services/terraform.tfvars
rm -f terraform/services/terraform.tfstate
rm -f terraform/vault.auto.tfvars
rm -f cluster-info.json hosts.json
# Optionally remove crypto directory:
rm -rf crypto/
```
