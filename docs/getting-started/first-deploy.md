# First Deployment

Selecting option 1 from the setup menu runs a complete deployment from scratch. This page explains each phase in detail so you know what is happening and what to expect.

## Before you start

- `bootstrap.yml` must be configured (see [Bootstrap Configuration](bootstrap.md))
- All [prerequisites](prerequisites.md) must be installed
- Your Proxmox host must be reachable from your workstation
- The network CIDR and gateway in `bootstrap.yml` must be correct

## Running the deployment

```bash
./setup.sh
# Select: 1) Deploy all services
```

Total time: approximately 20-40 minutes depending on network speed and hardware.

## Phase 1: Bootstrap

**What it does:** Reads `bootstrap.yml`, connects to Proxmox, and generates all configuration files.

Steps:
1. Generates SSH key pairs (`crypto/labenterpriseadmin`, `crypto/labadmin`)
2. Connects to Proxmox via SSH using the root password
3. Discovers all cluster nodes and their IPs
4. Auto-detects network bridges and storage pools
5. Creates `hashicorp@pam` API user with minimal permissions
6. Generates `terraform/terraform.tfvars`, `packer/packer.auto.pkrvars.hcl`, `cluster-info.json`
7. Distributes SSH keys to all discovered Proxmox nodes

After this phase, the root password is no longer needed. All subsequent operations use the API token saved in `crypto/proxmox-credentials.json`.

## Phase 2: Packer Templates

**What it does:** Builds the VM templates that Terraform will clone.

!!! info "Templates are cached"
    If VM templates 9001 (docker) and 9002 (nomad) already exist on Proxmox, this phase is skipped entirely.

Templates built:
- **9999** (base-ubuntu): Ubuntu 24.04 cloud image, imported via `qm importdisk`, converted to template
- **9001** (ubuntu-docker): Clones 9999, installs Docker CE, GlusterFS client, acme.sh
- **9002** (ubuntu-nomad): Clones 9999, installs HashiCorp Nomad, Consul, keepalived

Build commands run inside the Packer Docker container:

```bash
docker compose run packer init .
docker compose run packer build -only='base-*.*' .
docker compose run packer build -only='ubuntu-docker.*' -only='ubuntu-nomad.*' .
```

This phase takes the longest — typically 10-20 minutes for the first build.

## Phase 3: Layer 1 Infrastructure (Terraform)

**What it does:** Deploys the Nomad cluster and Vault container via Terraform. DNS is not deployed yet (it needs Vault secrets for passwords).

Resources created:
- `module.nomad`: 3 Nomad VMs (nomad01, nomad02, nomad03), cloned from template 9002
- GlusterFS directories on each Nomad VM
- `nomad_job.vault`: Vault container deployed on nomad01 (TLS disabled initially)

The Nomad VMs are provisioned via cloud-init with:
- Hostname, DNS suffix, SSH authorized key
- Nomad agent configuration with retry_join pointing to peer IPs
- GlusterFS configured and mounted at `/srv/gluster/nomad-data`
- Docker and Nomad services started

Vault starts with `tls_disable = true` for bootstrap. TLS is enabled later in Phase 4 after Vault PKI issues a certificate.

## Phase 4: Vault Initialization

**What it does:** Initializes Vault, generates the unseal key and root token, and writes Layer 2 configuration.

Steps:
1. Waits for Vault to respond at `http://<nomad01-ip>:8200`
2. Calls `PUT /v1/sys/init` with 1 key share, threshold 1
3. Saves unseal key and root token to `crypto/vault-credentials.json` (chmod 600)
4. Unseals Vault
5. Writes `terraform/services/terraform.tfvars` with Vault address, token, and service settings

!!! warning "Save vault-credentials.json"
    The unseal key and root token are saved to `crypto/vault-credentials.json`. This file is git-ignored. If you lose it and Vault restarts, you will not be able to unseal Vault and all secrets will be inaccessible.

If Vault was previously initialized but `vault-credentials.json` is missing, the script detects this and performs an automatic recovery: it stops the Vault job, wipes the data directory, and re-initializes fresh.

## Phase 5: Layer 2 Services (Terraform)

**What it does:** Configures Vault and deploys services using the root token written in Phase 4.

Layer 2 (`terraform/services/`) applies:

1. **Vault PKI**: Two-tier CA — `pki/` root (10-year TTL) and `pki_int/` intermediate (5-year TTL)
2. **Vault JWT auth**: `jwt-nomad` auth backend trusting Nomad's JWKS endpoint
3. **Vault policies**: Per-service policies (authentik, samba-ad, backup, lam, netbox, tailscale)
4. **Vault KV secrets**: Generated passwords for all services stored at `secret/<service>`
5. **Service directories**: GlusterFS subdirectories for each service
6. **Traefik TLS cert**: Wildcard `*.<dns-suffix>` cert issued from `pki_int`, written to GlusterFS
7. **Nomad job: traefik**: Traefik deployed as a system job (runs on all nodes)
8. **DNS records**: Pi-hole custom DNS entries for all service hostnames

After this, Vault redeploys with TLS enabled using the cert issued by its own PKI:

```
vault.<dns-suffix>   -> Traefik -> Vault (HTTPS/8200)
traefik.<dns-suffix> -> Traefik -> Traefik dashboard (8081)
nomad.<dns-suffix>   -> Traefik -> Nomad UI (4646)
auth.<dns-suffix>    -> Traefik -> Authentik (9443)
```

## Phase 6: DNS Deployment

**What it does:** Deploys the Pi-hole LXC containers (one per Proxmox node) with passwords from Vault.

- Pi-hole v6 configured with Unbound for DNS-over-TLS
- Gravity Sync configured: dns-01 is the primary, dns-02/03 sync from it
- Custom DNS records for all services added to Pi-hole
- Proxmox nodes' DNS updated to point to Pi-hole

!!! info "Why DNS deploys after Vault"
    Pi-hole admin passwords are randomly generated by Terraform and stored in Vault. Deploying DNS after Vault ensures the containers receive their actual passwords rather than placeholder values.

## Phase 7: Authentik Deployment

**What it does:** Deploys Authentik and configures applications in a two-step process.

**Step 1 — Deploy job:** Authentik container starts with secrets fetched from Vault via WIF (JWT). Database initializes with the admin password from Vault.

**Step 2 — Configure apps:** Once Authentik reports healthy, Terraform reads the API token from Vault and configures:
- Authentik applications (Pi-hole, Traefik, Nomad, Vault, and any enabled optional services)
- OAuth2 provider for Vault OIDC login
- Proxy providers for admin-only services
- Infrastructure Admins group

The `akadmin` password is also synced via the Authentik API to ensure it matches Vault even if the database was initialized with a stale password from a previous deployment.

## Deployment Summary

When all phases complete, the script prints service URLs:

```
Services:
  Vault:     https://<nomad01-ip>:8200
  Traefik:   http://<nomad01-ip>:8081
  Nomad:     http://<nomad01-ip>:4646
  Authentik: https://<nomad01-ip>:9443
```

DNS-based URLs (after configuring your client to use Pi-hole for DNS):

```
https://vault.<dns-suffix>
https://traefik.<dns-suffix>
https://nomad.<dns-suffix>
https://auth.<dns-suffix>
https://pihole.<dns-suffix>
```

## What to do after deployment

1. **Configure client DNS**: Point your workstation's DNS to the Pi-hole IP (or HA VIP if enabled). This makes all `*.<dns-suffix>` hostnames resolve.

2. **Import the root CA**: The Vault PKI root CA must be trusted by your browser. Download it from `https://vault.<dns-suffix>/v1/pki/ca/pem` and add it to your system certificate store.

3. **Log in to Authentik**: Browse to `https://auth.<dns-suffix>`. Log in with `akadmin` and the password from `crypto/vault-credentials.json` (field: look up in Vault at `secret/authentik`, key `admin_password`).

4. **Deploy optional services**: Select options 3-6 from the menu for Kasm, Samba AD, Uptime Kuma, or Netbox.

## Resuming a failed deployment

If the deployment fails partway through:

- **Packer failed**: Re-run option 1. If templates were already built, Phase 2 is skipped.
- **Layer 1 Terraform failed**: Re-run option 1. Terraform is idempotent.
- **Vault init failed but Vault is running**: The script will detect the inconsistent state and recover automatically.
- **Layer 2 failed**: From the developer menu (`--dev`), use option `d5` to re-apply Layer 2 only.

If you want to start completely fresh, use option 9 (Purge entire deployment) before re-running option 1.
