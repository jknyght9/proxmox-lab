# Setup Menu Reference

The `setup.sh` script provides an interactive menu for all deployment and management operations.

## Running the Menu

```bash
./setup.sh          # Standard menu
./setup.sh --dev    # Standard menu + developer tools
```

## Standard Menu

### Setup

#### 1) Deploy all services

Runs the complete deployment from scratch:

- Phase 1: Bootstrap (reads `bootstrap.yml`, creates API credentials, generates `terraform.tfvars`)
- Phase 2: Packer template builds (skipped if templates 9001, 9002 already exist)
- Phase 3: Layer 1 Terraform (Nomad cluster, Vault job)
- Phase 4: Vault initialization
- Phase 5: Layer 2 Terraform (PKI, secrets, Traefik, DNS, Authentik)

Total time: 20-40 minutes on first run.

#### 2) Enable HA (keepalived VIPs)

Reads HA settings from `bootstrap.yml` and applies them:
- Updates `terraform/terraform.tfvars` with HA variables
- Applies Layer 1 Terraform (configures keepalived on all nodes)
- Updates `terraform/services/terraform.tfvars` with VIP addresses
- Applies Layer 2 Terraform (updates DNS records to point to VIPs)

Requires `ha_dns_enabled` or `ha_traefik_enabled` to be set in `bootstrap.yml`.

### Optional Services

#### 3) Kasm Workspaces

Deploys a Kasm Workspaces VM (VMID 930). Requires the Docker template (9001) to exist.

Equivalent to:
```bash
docker compose run terraform apply -auto-approve -var "deploy_kasm=true"
```

#### 4) Samba AD + LDAP Account Manager

Deploys Samba AD domain controllers and the LDAP Account Manager web UI. Sets up service accounts and Pi-hole DNS forwarding for the AD realm.

Uses `enableService samba_ad` and `enableService lam`.

#### 5) Uptime Kuma (monitoring)

Deploys Uptime Kuma service monitoring. Creates a `status.<dns-suffix>` DNS record.

#### 6) Netbox (inventory management)

Deploys Netbox and auto-populates it with infrastructure inventory (VMs, LXC containers, Proxmox nodes, UniFi devices if configured).

Two-phase deployment:
1. Netbox job starts and database initializes
2. `configure_netbox = true` triggers inventory population via REST API

### Management

#### 7) Rollback services (Layer 2)

Destroys all Layer 2 service resources while preserving infrastructure:

- Stops Nomad jobs (Traefik, Authentik, Samba AD, etc.)
- Destroys Vault PKI configuration, JWT auth, policies, secrets
- Removes DNS records from Pi-hole
- Removes Authentik apps and providers
- Resets DNS on Nomad VMs and Proxmox nodes to gateway

Infrastructure (Nomad VMs, Pi-hole LXCs, Kasm) remains intact. After rollback, re-deploy services via option 1 starting from Phase 4, or use `d5` from the developer menu.

**Confirmation required:** `y/N`

#### 8) Rollback infrastructure (Layer 1 + 2)

Destroys all VMs and LXC containers. Also destroys Layer 2 resources first for clean shutdown.

!!! danger "Data loss"
    GlusterFS data lives on VM disks. Destroying VMs wipes all service data (Vault secrets, Authentik database, Samba AD, etc.). There is no recovery from this without a backup.

Steps:
1. Layer 2 destroy (clean service shutdown)
2. Reset Proxmox DNS to gateway
3. Layer 1 destroy (all VMs and LXC containers)
4. Clean generated config files
5. Optionally remove Packer templates (9001, 9002)

**Confirmation required:** Type `DESTROY`

#### 9) Purge entire deployment

Full reset to pre-install state. Removes:
- All VMs and LXC containers (via direct Proxmox API)
- Packer templates (9999, 9001, 9002)
- Cloud-init snippets
- `hashicorp@pam` API user and `HashicorpBuild` role
- DNS configuration (reset to gateway)
- All generated config files (`terraform.tfvars`, `cluster-info.json`, `crypto/`)

Use this to start completely fresh, or to clean up after a failed deployment that left resources in an inconsistent state.

**Confirmation required:** Multiple prompts

#### 0 or q) Exit

Exits the menu.

## Developer Menu (--dev flag)

Run with `./setup.sh --dev` to access additional options.

### d1) Rebuild base Ubuntu template

Rebuilds the Packer Ubuntu 24.04 base template (VMID 9999). All other Packer templates (Docker, Nomad) clone from this. Use after significant OS updates or to refresh the cloud-init vendor snippet.

```bash
packer build -only='base-ubuntu.*' .
```

### d2) Rebuild service templates

Rebuilds the Docker (9001) and Nomad (9002) templates from the current base Ubuntu template. Use when you need to update Nomad, Docker, or other software installed in the templates.

```bash
packer build -only='ubuntu-docker.*' -only='ubuntu-nomad.*' .
```

### d3) Reset Proxmox user/token/role

Deletes and recreates the `hashicorp@pam` API user, `HashicorpBuild` role, and API token. Use if the API credentials become invalid or permissions need to be reset.

Requires root SSH access to Proxmox (uses the root password from `bootstrap.yml`).

### d4) Deploy infrastructure (Nomad, Vault, DNS)

Applies the full Layer 1 Terraform. Deploys or updates all infrastructure:
- Nomad cluster
- Pi-hole DNS cluster
- Vault Nomad job
- Kasm (if `deploy_kasm=true`)

```bash
docker compose run terraform apply -auto-approve
```

### d5) Deploy services (Traefik, Authentik, secrets)

Applies the full Layer 2 Terraform. Requires Layer 2 to be initialized (i.e., Vault must be running and `terraform/services/terraform.tfvars` must exist).

```bash
docker compose run terraform-services apply -auto-approve
```

### d6) Deploy Nomad cluster only

Applies Layer 1 Terraform targeting only the Nomad module. Useful for updating Nomad VM configuration without affecting DNS or other resources.

### d7) Deploy DNS only

Applies Layer 1 Terraform targeting only the Pi-hole DNS module.

### d8) Deploy Vault only

Applies Layer 1 Terraform targeting the Vault job and directories, then runs Vault initialization and unseal.

### d9) Deploy Traefik only

Deploys or redeployes Traefik via `enableService traefik`. Also re-issues the wildcard TLS certificate from Vault PKI.

### d10) Deploy Authentik only

Deploys or redeploys Authentik via `enableService authentik`. Runs the two-phase deploy (job start, then app configuration).

### d11) Rebuild DNS records

Re-applies only the DNS record Terraform resources without touching other Layer 2 resources. Use after adding services or changing the DNS suffix.

## Configuration Change Detection

When the menu starts, it compares `bootstrap.yml` against the deployed state. If changes are detected (such as new HA settings), it shows an alert:

```
  Configuration changes detected in bootstrap.yml:
    - Enable DNS HA (VIP: 192.168.1.3/24)
    - Enable Traefik HA (VIP: 192.168.1.100/24)
    *) Apply configuration changes
```

Select `*` to apply the detected changes. This calls the same logic as option 2.

## Using Terraform Directly

You can also run Terraform directly via Docker Compose:

```bash
# Layer 1 (infrastructure)
docker compose run terraform init
docker compose run terraform plan
docker compose run terraform apply -auto-approve

# Layer 2 (services)
docker compose run terraform-services init
docker compose run terraform-services plan
docker compose run terraform-services apply -auto-approve

# Target a specific resource
docker compose run terraform-services apply -auto-approve \
  -target=nomad_job.authentik
```

## Using Nomad Directly

```bash
# List all jobs
docker compose run --rm nomad job status

# View job details
docker compose run --rm nomad job status vault

# View allocation logs
docker compose run --rm nomad alloc logs -job vault

# Stop a job
docker compose run --rm nomad job stop -purge vault

# List registered services
docker compose run --rm nomad service list
```

Note: Update `NOMAD_ADDR` in `compose.yml` if your nomad01 IP differs from the default.
