# Backup & Recovery

This page covers what to back up, how to perform rollbacks, how to rebuild infrastructure from scratch, and how to handle Vault unseal after restarts.

---

## What to Back Up

### Critical Files

These files are essential for recovering or rebuilding the lab. Back them up regularly to a secure location outside the lab environment.

| File / Directory | Purpose | Sensitivity |
|-----------------|---------|-------------|
| `crypto/vault-credentials.json` | Vault unseal key and root token | **Extremely sensitive** |
| `crypto/lab-deploy` | SSH private key for all lab VMs/LXCs | **Extremely sensitive** |
| `crypto/lab-deploy.pub` | SSH public key | Low |
| `crypto/root_ca.crt` | Root CA certificate | Low |
| `cluster-info.json` | Cluster topology, network config, storage settings | Moderate |
| `hosts.json` | Deployed host IPs for DNS records | Low |
| `terraform/terraform.tfvars` | Terraform variable values | Moderate |
| `packer/packer.auto.pkrvars.hcl` | Packer variable values | Moderate |

!!! danger "Protect secrets"
    The `crypto/` directory contains highly sensitive material. Never commit it to version control, store it in unencrypted cloud storage, or transmit it over insecure channels. Consider using an encrypted backup solution or a hardware-encrypted USB drive.

### Vault Data

Vault stores secrets for Authentik, Samba AD, and other services. The Vault data is persisted on GlusterFS at `/srv/gluster/nomad-data/vault/` across all Nomad nodes.

**What to back up:**

- `crypto/vault-credentials.json` (unseal key and root token)
- Optionally, the Vault data directory: `/srv/gluster/nomad-data/vault/`

**Export secrets manually:**

```bash
# Export a secret from Vault
docker compose run --rm nomad alloc exec -job vault vault kv get -format=json secret/data/authentik
```

### GlusterFS Persistent Data

All Nomad service data lives on the GlusterFS replicated volume at `/srv/gluster/nomad-data/`. GlusterFS replicates data across all 3 Nomad nodes, providing built-in redundancy. However, this does not protect against data corruption or accidental deletion.

**Important directories:**

```
/srv/gluster/nomad-data/
  +-- vault/          # Vault storage backend
  +-- traefik/        # Traefik ACME certificates
  +-- authentik/      # Authentik PostgreSQL, Redis, media
  +-- samba-dc01/     # Samba AD Domain Controller 1
  +-- samba-dc02/     # Samba AD Domain Controller 2
```

To back up GlusterFS data, SSH into any Nomad node and copy the relevant directories:

```bash
ssh user@<nomad01-ip> "sudo tar czf /tmp/nomad-data-backup.tar.gz -C /srv/gluster nomad-data"
scp user@<nomad01-ip>:/tmp/nomad-data-backup.tar.gz ./backups/
```

### Terraform State

Terraform state is stored locally in `terraform/terraform.tfstate`. This file tracks all resources Terraform manages.

!!! warning
    If you lose the Terraform state file, Terraform will not know about existing infrastructure and may attempt to recreate resources. Back up `terraform.tfstate` and `terraform.tfstate.backup` regularly.

---

## Rollback Options

Proxmox Lab provides three levels of rollback, accessible through the setup.sh menu.

### Option 13: Terraform Rollback

```bash
./setup.sh
# Select option 13: Rollback (Terraform)
```

This runs `terraform destroy` selectively, allowing you to tear down specific modules while keeping others. Terraform will prompt for confirmation before destroying resources.

**Use when:**

- A specific module deployment failed and you need to start over
- You want to remove a service without affecting the rest of the infrastructure

### Option 14: Emergency Purge

```bash
./setup.sh
# Select option 14: Purge (Emergency)
```

This bypasses Terraform and directly destroys VMs and LXC containers via SSH to the Proxmox host. It uses Proxmox CLI commands (`qm destroy`, `pct destroy`) to forcefully remove resources.

**Use when:**

- Terraform state is corrupted or out of sync with actual infrastructure
- Terraform destroy fails or hangs
- You need to quickly remove resources that Terraform cannot manage

!!! warning
    Emergency purge does not update Terraform state. After an emergency purge, you may need to clean up stale state entries with `terraform state rm`.

### Option 15: Full Purge

```bash
./setup.sh
# Select option 15: Purge entire deployment
```

This is the nuclear option. It resets all Proxmox nodes to their pre-install state, removing all VMs, LXCs, templates, and configuration created by the project.

**Requires typing `PURGE` to confirm.**

**Use when:**

- You want to start completely from scratch
- You are decommissioning the lab
- Something is fundamentally broken and incremental fixes are not viable

!!! danger
    This is irreversible. All lab data, VMs, containers, and templates will be destroyed. Ensure you have backed up everything you need before proceeding.

---

## Rebuilding from Scratch

If you need to rebuild the entire lab (after a full purge or on a new Proxmox installation):

### 1. Restore Configuration Files

Copy your backed-up configuration files back into place:

```bash
# Restore configuration
cp backup/terraform.tfvars terraform/terraform.tfvars
cp backup/packer.auto.pkrvars.hcl packer/packer.auto.pkrvars.hcl
cp backup/cluster-info.json cluster-info.json
```

### 2. Run Full Setup

```bash
# Option A: Full setup with new SSH keys
./setup.sh <PROXMOX_IP> <PROXMOX_PASSWORD>

# Option B: Full setup with existing SSH keys (if you restored crypto/)
./setup.sh
# Select option 2: New installation (skip SSH)
```

### 3. Redeploy Services

After infrastructure is provisioned, deploy Nomad services:

```bash
./setup.sh
# Select option 3: Deploy all services
```

### 4. Restore Vault Secrets

If you have a previous Vault data backup:

```bash
# SSH into nomad01 and restore the Vault directory
ssh user@<nomad01-ip> "sudo tar xzf /tmp/vault-backup.tar.gz -C /srv/gluster/nomad-data/"
```

Otherwise, you will need to reinitialize Vault and re-enter all secrets.

### 5. Rebuild DNS Records

```bash
./setup.sh
# Select option 10: Build DNS records
```

---

## Vault Unseal After Restart

Vault seals itself automatically whenever the Nomad job restarts, the container is recreated, or the node reboots. A sealed Vault cannot serve any requests.

### Checking Seal Status

```bash
# Check if Vault is sealed
curl -s http://<nomad01-ip>:8200/v1/sys/health | jq .

# Look for "sealed": true in the response
```

A sealed Vault returns HTTP 503 with `"sealed": true`.

### Unsealing Vault

You need the unseal key from `crypto/vault-credentials.json`:

```bash
# Get the unseal key
cat crypto/vault-credentials.json | jq -r '.unseal_key'

# Unseal Vault
curl -X PUT http://<nomad01-ip>:8200/v1/sys/unseal \
  -d "{\"key\": \"$(cat crypto/vault-credentials.json | jq -r '.unseal_key')\"}"
```

Or through the Vault UI:

1. Navigate to `https://vault.<domain>` or `http://<nomad01-ip>:8200`
2. Enter the unseal key from `crypto/vault-credentials.json`
3. Click **Unseal**

### Automating Unseal

Vault in this lab uses a single unseal key (Shamir's Secret Sharing with a threshold of 1). The setup process handles initial unsealing, but you must manually unseal after any restart.

!!! tip "After node reboot"
    If a Nomad node reboots, wait for the Nomad agent to start and schedule the Vault job before attempting to unseal. You can check with:
    ```bash
    docker compose run --rm nomad job status vault
    ```
    Wait until the allocation shows `running` before unsealing.

---

## Recovery Scenarios

### Scenario: Single Nomad Node Failure

If one Nomad node goes down (e.g., nomad02 or nomad03):

1. The Nomad cluster maintains quorum with 2 of 3 nodes
2. GlusterFS continues operating in degraded mode
3. Services pinned to nomad01 are unaffected
4. When the node recovers, it rejoins automatically

**Action needed:** None for services. Monitor GlusterFS heal status:

```bash
ssh user@<nomad01-ip> "sudo gluster volume heal nomad-data info"
```

### Scenario: nomad01 Failure

Since all services are pinned to nomad01, this is more impactful:

1. All Nomad services (Traefik, Vault, Authentik, Samba AD) go offline
2. The Nomad cluster may lose quorum if nomad01 was the leader
3. GlusterFS volume is still available on other nodes

**Recovery:**

1. Restore nomad01 (reboot or rebuild via Terraform)
2. Wait for Nomad to rejoin and elect a leader
3. Jobs will be rescheduled automatically
4. Unseal Vault after it starts

### Scenario: Lost Vault Credentials

If `crypto/vault-credentials.json` is lost and Vault is sealed:

1. **Vault data is unrecoverable** without the unseal key
2. Clean up Vault data: `sudo rm -rf /srv/gluster/nomad-data/vault/*`
3. Restart the Vault job to trigger reinitialization
4. New credentials will be saved to `crypto/vault-credentials.json`
5. Re-enter all secrets (Authentik, Samba AD, etc.)

### Scenario: Corrupted Terraform State

If `terraform.tfstate` is corrupted or lost:

1. Use emergency purge (menu option 14) to clean up existing resources
2. Delete the corrupted state file
3. Run `terraform init` to start fresh
4. Redeploy with `terraform apply`
