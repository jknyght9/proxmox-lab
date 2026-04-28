# Bootstrap Configuration

`bootstrap.yml` is the single source of truth for initial setup. It contains your network configuration, Proxmox credentials, and optional feature settings. Everything else — Terraform variables, Packer variables, API tokens, SSH keys — is generated automatically from this file.

## Creating bootstrap.yml

```bash
cp bootstrap.yml.example bootstrap.yml
$EDITOR bootstrap.yml
```

## Required Settings

These settings must be configured before running setup:

```yaml
proxmox:
  ip: "<proxmox-ip>"       # IP of any Proxmox node; cluster is auto-detected
  password: "<password>"   # Root password, used once to create API token

network:
  cidr: "<network-cidr>"   # e.g., "192.168.1.0/24"
  gateway: "<gateway-ip>"  # e.g., "192.168.1.1"
  # bridge: "vmbr0"        # Optional: override auto-detected bridge

dns_suffix: "<dns-suffix>" # e.g., "mylab.lan" — used for all service hostnames
```

### What happens during bootstrap

When you run option 1 (or any option that triggers bootstrap), the script:

1. Connects to Proxmox via SSH using the root password
2. Discovers all cluster nodes and their IPs
3. Creates a `hashicorp@pam` API user with the `HashicorpBuild` role
4. Saves an API token to `crypto/proxmox-credentials.json`
5. Auto-detects available storage pools and network bridges
6. Generates `terraform/terraform.tfvars` with all infrastructure settings
7. Generates `packer/packer.auto.pkrvars.hcl` with build settings
8. Generates `cluster-info.json` with cluster topology

The root password is only used during this bootstrap phase. All subsequent operations use the API token.

## Optional Settings

### High Availability VIPs

HA uses keepalived VRRP to provide virtual IPs that float between nodes. When a node fails, the VIP moves to the next healthy node automatically.

```yaml
ha_dns_enabled: true
ha_dns_vip: "<vip-ip>/24"          # e.g., "192.168.1.3/24"
ha_dns_vrrp_router_id: 51          # Unique ID 1-255, must not conflict with other VRRP
ha_dns_vrrp_password: "pihole-ha"  # Max 8 characters

ha_traefik_enabled: true
ha_traefik_vip: "<vip-ip>/24"      # e.g., "192.168.1.100/24"
ha_traefik_vrrp_router_id: 53
ha_traefik_vrrp_password: "trafk-ha"
```

!!! info "HA requires a 3-node cluster"
    With a single Proxmox node, HA VIPs have no secondary node to fail over to and should be left disabled.

!!! warning "VRRP router IDs must be unique"
    If you have other VRRP devices on your network (such as a router using VRRP/HSRP), choose router IDs that do not conflict. IDs are 1-255.

After changing HA settings in `bootstrap.yml`, select option 2 from the menu to apply them without a full redeploy.

### Storage Overrides

By default, the bootstrap script auto-detects storage pools. Override if needed:

```yaml
storage:
  templates: "nfs-templates"  # Storage for Packer VM templates (must be shared in a cluster)
  runtime: "local-lvm"        # Storage for running VMs and LXC containers
```

### Roaming Profiles (Windows)

Maps a network drive on domain login via Samba AD group policy:

```yaml
profile_server: "nas.<dns-suffix>"  # File server FQDN or IP
profile_share: "profiles"            # SMB share name
profile_drive_letter: "P"            # Drive letter to map
```

Requires Samba AD to be deployed (menu option 4).

### Authentik AD Sync

Automatically syncs Samba AD users and groups into Authentik:

```yaml
authentik_ad_sync: true
authentik_sync_interval: 300    # Sync interval in seconds (default: 5 minutes)
```

Requires both Authentik and Samba AD to be deployed.

### NAS Domain Join

Automatically joins TrueNAS SCALE or Synology DSM to the Samba AD domain:

```yaml
nas_servers:
  - name: "truenas-01"               # Friendly name (used as Vault key)
    type: "truenas"                   # "truenas" or "synology"
    address: "<truenas-ip>"           # Management IP or FQDN
    api_key: "<truenas-api-key>"      # Generate in TrueNAS UI: System > API Keys

  - name: "synology-01"
    type: "synology"
    address: "<synology-ip>"
    admin_user: "admin"               # DSM admin account (used for API auth only)
    admin_password: "<password>"      # DSM admin password
```

!!! note "TrueNAS API key generation"
    In TrueNAS SCALE: System > API Keys > Add. Give it a descriptive name and copy the key. The key is stored in Vault at `secret/nas/<name>` after first use.

!!! note "Synology credentials"
    Synology uses DSM admin credentials for the initial API authentication. These are stored in Vault after first use. The actual domain join uses the `domain-join-svc` service account created automatically by Terraform.

### UniFi Controller Integration

Syncs network devices (switches, APs, gateways) into Netbox inventory:

```yaml
unifi_address: "<unifi-ip>"    # Controller IP or FQDN
unifi_api_key: "<api-key>"     # Settings > Control Plane > API Key (UniFi OS 4.x+)
unifi_site: "default"           # Site name (usually "default")
```

Requires Netbox to be deployed (menu option 6).

## Generated Files

After bootstrap completes, these files are created or updated:

| File | Contents |
|------|----------|
| `terraform/terraform.tfvars` | All Layer 1 variables (provider, network, storage, DNS) |
| `packer/packer.auto.pkrvars.hcl` | All Packer variables (API credentials, storage, bridge) |
| `cluster-info.json` | Cluster topology, node IPs, network settings |
| `crypto/proxmox-credentials.json` | API token for `hashicorp@pam` |
| `crypto/labenterpriseadmin` / `.pub` | SSH key for Proxmox node administration |
| `crypto/labadmin` / `.pub` | SSH key for VM/container administration |

!!! warning "Never commit these files"
    All files in `crypto/` and `terraform/*.tfvars` are git-ignored. Do not commit them. They contain secrets and credentials.

After Vault initialization (Phase 3 of option 1), these are also created:

| File | Contents |
|------|----------|
| `terraform/services/terraform.tfvars` | Layer 2 variables (Vault token, service toggles) |
| `crypto/vault-credentials.json` | Vault unseal key and root token |

## Changing Settings After Deployment

**Network and DNS settings**: Edit `bootstrap.yml` and re-run option 1. The bootstrap script will regenerate `terraform.tfvars` and re-apply.

**HA settings**: Edit `bootstrap.yml` and select option 2 (Enable HA). The menu detects changes in `bootstrap.yml` and prompts you to apply them.

**Adding a NAS**: Add the entry to `nas_servers` in `bootstrap.yml` and re-run option 1. The Terraform `nas_domain_join` resource is idempotent — already-joined systems are skipped.

## Full Example

```yaml
proxmox:
  ip: "192.168.1.10"
  password: "your-proxmox-root-password"

network:
  cidr: "192.168.1.0/24"
  gateway: "192.168.1.1"

dns_suffix: "mylab.lan"

# HA configuration
ha_dns_enabled: true
ha_dns_vip: "192.168.1.3/24"
ha_dns_vrrp_router_id: 51
ha_dns_vrrp_password: "pihole1"

ha_traefik_enabled: true
ha_traefik_vip: "192.168.1.100/24"
ha_traefik_vrrp_router_id: 53
ha_traefik_vrrp_password: "trafk1"

# Roaming profiles
profile_server: "nas.mylab.lan"
profile_share: "profiles"
profile_drive_letter: "P"

# NAS integration
nas_servers:
  - name: "truenas-01"
    type: "truenas"
    address: "192.168.1.50"
    api_key: "abc123..."
```
