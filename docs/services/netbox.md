# Netbox

Netbox is an infrastructure inventory and documentation tool. When deployed, it is automatically populated with your lab's VMs, LXC containers, Proxmox physical nodes, and optionally UniFi network devices.

## Overview

| Property | Value |
|----------|-------|
| **Nomad Job** | `netbox` |
| **Node** | Pinned to `nomad01` |
| **Port** | 8080 (HTTP) |
| **Vault Role** | `netbox` (WIF) |
| **Storage** | `/srv/gluster/nomad-data/netbox/` (GlusterFS) |
| **Secrets** | `secret/netbox` in Vault |

## Deployment

Select option 6 from the setup menu:

```bash
./setup.sh
# 6) Netbox (inventory management)
```

Netbox uses a two-phase deployment:
1. **Phase 1**: Netbox Nomad job starts, database initializes
2. **Phase 2**: `configure_netbox = true` triggers `null_resource.netbox_inventory` to populate inventory

## What gets auto-populated

### VMs and LXC containers (from Terraform)

All VMs defined in Layer 1 Terraform (Nomad nodes, Kasm) and LXC containers (Pi-hole nodes) are registered automatically:
- VM name, vCPU count, RAM, disk size
- IP address with DNS name
- Virtual interface (eth0)
- Assigned to cluster with site "Home Lab"

### Proxmox physical nodes

For each Proxmox cluster node, Netbox discovers:
- Manufacturer and model (via `dmidecode`)
- CPU model and core count
- RAM total
- Network interfaces with MAC addresses and detected speed
- Storage disks with size and model
- Primary IP address

This is gathered by SSH-ing into each Proxmox node from nomad01 during the Terraform apply.

### Nomad services

Service records are created for running Nomad jobs:
- Vault (port 8200)
- Traefik (ports 80, 443)
- Authentik (ports 9000, 9443)
- And any other enabled services

### UniFi network devices (optional)

When `unifi_address` is configured in `bootstrap.yml`, Netbox also populates:
- Switches, access points, gateways from UniFi
- Interface details (speed, type, MAC)
- Switch port configuration
- Network VLANs and prefixes

## Accessing Netbox

Via DNS (through Traefik):
```
https://netbox.<dns-suffix>
```

Direct access:
```
http://<nomad01-ip>:8080
```

Default credentials:
- **Username**: `admin`
- **Password**: From Vault: `vault kv get -field=admin_password secret/netbox`

## Re-running Inventory Sync

To update Netbox after infrastructure changes, re-apply Layer 2:

```bash
./setup.sh --dev
# d5) Deploy services (Traefik, Authentik, secrets)
```

Or target just the inventory resources:

```bash
docker compose run terraform-services apply -auto-approve \
  -target=null_resource.netbox_inventory \
  -target=null_resource.netbox_proxmox_devices \
  -target=null_resource.netbox_unifi_devices
```

## Secrets

Netbox secrets are stored in Vault at `secret/netbox`:

| Key | Purpose |
|-----|---------|
| `secret_key` | Netbox application secret key (50 chars, random) |
| `postgres_password` | PostgreSQL database password |
| `admin_password` | Initial admin user password |
| `admin_email` | Admin user email |
| `api_token` | API token used by Terraform to configure Netbox |

## Troubleshooting

### Netbox not accessible

Check the Nomad job status:

```bash
ssh labadmin@nomad01 "nomad job status netbox"
ssh labadmin@nomad01 "nomad alloc logs -job netbox"
```

### Inventory not populated

The `netbox_inventory` resource requires `configure_netbox = true` in `terraform/services/terraform.tfvars`. This is set automatically when you deploy via option 6 (after Netbox is running).

If you need to force a re-run:

```bash
# Remove the Terraform resource state so it re-runs
docker compose run terraform-services state rm null_resource.netbox_inventory
docker compose run terraform-services apply -auto-approve
```

### UniFi sync fails

Check the error in the Terraform output. Common issues:
- UniFi controller is using a self-signed certificate (SSL errors)
- API key is incorrect or expired
- Site name is wrong (most setups use "default")

Test the UniFi API manually:

```bash
curl -sk -H "X-API-Key: <api-key>" \
  "https://<unifi-ip>/proxy/network/api/s/default/stat/device" | jq '.meta'
```
