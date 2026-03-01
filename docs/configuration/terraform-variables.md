# Terraform Variables

All Terraform variables used by Proxmox Lab, grouped by function. Variables are defined in `terraform/variables.tf` and values are provided through `terraform/terraform.tfvars`.

!!! tip "Auto-generation"
    Most variables are auto-populated by `setup.sh` during initial deployment. Variables marked **auto-generated** are written to `terraform.tfvars` by the setup script based on your responses to its interactive prompts. You can also configure them manually.

!!! warning "Sensitive Data"
    Never commit `terraform.tfvars` to version control. It contains passwords and API tokens. The file is included in `.gitignore` by default.

---

## Authentication

These variables configure how Terraform authenticates with the Proxmox API. Two authentication methods are supported: API token (recommended) and username/password (fallback).

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `proxmox_api_url` | `string` | Yes | -- | Proxmox API endpoint URL (e.g., `https://10.1.50.210:8006/api2/json`) |
| `proxmox_api_token_id` | `string` | Yes | -- | API token ID (e.g., `terraform@pam!terraform-access-token`) |
| `proxmox_api_token` | `string` | Yes | -- | API token secret value |
| `proxmox_api_username` | `string` | Yes | -- | Proxmox username for password authentication (e.g., `root@pam`) |
| `proxmox_api_password` | `string` | Yes | -- | Proxmox password for authentication |
| `proxmox_target_node` | `string` | Yes | -- | Default Proxmox node name (e.g., `pve01`) |

!!! note "Authentication Methods"
    **Option 1 -- API Token (recommended):** Set `proxmox_api_token_id` and `proxmox_api_token`. This is the most secure method.

    **Option 2 -- Username/Password (fallback):** Set `proxmox_api_username` and `proxmox_api_password`. Used when API tokens are not available.

    Both options require `proxmox_api_url` to be set.

### Example

```hcl
# Option 1: API Token authentication (recommended)
proxmox_api_url      = "https://10.1.50.210:8006/api2/json"
proxmox_api_token_id = "terraform@pam!terraform-access-token"
proxmox_api_token    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Option 2: Username/password authentication (fallback)
proxmox_api_username = "root@pam"
proxmox_api_password = "your-password-here"
proxmox_target_node  = "pve01"
```

---

## Proxmox Cluster

These variables describe your Proxmox cluster topology and are used for multi-node provisioning (e.g., uploading cloud-init snippets to the correct node, running `pct exec` on SDN containers).

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `proxmox_node_ips` | `map(string)` | No | `{}` | Map of Proxmox node names to their management IP addresses |

This variable is **auto-generated** by `setup.sh`.

### Example

```hcl
proxmox_node_ips = {
  pve01 = "10.1.50.210"
  pve02 = "10.1.50.211"
  pve03 = "10.1.50.212"
}
```

---

## Network

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `network_interface_bridge` | `string` | Yes | -- | Proxmox network bridge for external traffic (e.g., `vmbr0`) |
| `network_gateway_address` | `string` | Yes | -- | Network gateway IP address for the external network |

Both are **auto-generated** by `setup.sh`.

### Example

```hcl
network_interface_bridge = "vmbr0"
network_gateway_address  = "10.1.50.1"
```

---

## Storage

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `lxc_storage` | `string` | No | `"local-lvm"` | Storage pool for LXC container root filesystems |
| `vm_storage` | `string` | No | `"local-lvm"` | Storage pool for VM disks (should match template storage for fast cloning) |

!!! tip "Storage Options"
    Common storage types:

    - `local-lvm` -- Default per-node LVM storage (single-node setups)
    - `ceph` or `ceph-pool-01` -- Ceph distributed storage (multi-node clusters)
    - `nfs-storage` -- NFS shared storage
    - `local` -- Directory-based local storage

    For multi-node Proxmox clusters, use shared storage so that VMs can be provisioned on any node.

### Example

```hcl
lxc_storage = "local-lvm"
vm_storage  = "local-lvm"
```

---

## DNS

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `dns_postfix` | `string` | Yes | -- | Domain suffix for all services (e.g., `mylab.lan`) |
| `dns_primary_ipv4` | `string` | Yes | -- | IP address of the primary DNS server (first dns node deployed) |
| `pihole_admin_password` | `string` | Yes (sensitive) | -- | Pi-hole web admin interface password |
| `pihole_root_password` | `string` | Yes (sensitive) | -- | LXC container root password for Pi-hole nodes |
| `dns_main_nodes` | `list(object)` | No | `[]` | Main DNS cluster node definitions (external network) |
| `dns_labnet_nodes` | `list(object)` | No | `[]` | Labnet SDN DNS cluster node definitions (internal network) |

The `dns_postfix` and `dns_primary_ipv4` are **auto-generated** by `setup.sh`. The node lists (`dns_main_nodes`, `dns_labnet_nodes`) are also **auto-generated** based on your Proxmox cluster size.

### DNS Node Object Schema

Both `dns_main_nodes` and `dns_labnet_nodes` use the same object structure:

```hcl
list(object({
  hostname    = string    # Container hostname (e.g., "dns-01")
  target_node = string    # Proxmox node to deploy on (e.g., "pve01")
  ip          = string    # Static IP with CIDR (e.g., "10.1.50.3/24")
  gw          = string    # Gateway IP (e.g., "10.1.50.1")
}))
```

### Example

```hcl
dns_postfix      = "mylab.lan"
dns_primary_ipv4 = "10.1.50.3"

pihole_admin_password = "secure-admin-password"
pihole_root_password  = "secure-root-password"

dns_main_nodes = [
  { hostname = "dns-01", target_node = "pve01", ip = "10.1.50.3/24", gw = "10.1.50.1" },
  { hostname = "dns-02", target_node = "pve02", ip = "10.1.50.4/24", gw = "10.1.50.1" },
  { hostname = "dns-03", target_node = "pve03", ip = "10.1.50.5/24", gw = "10.1.50.1" },
]

dns_labnet_nodes = [
  { hostname = "labnet-dns-01", target_node = "pve01", ip = "172.16.0.3/24", gw = "172.16.0.1" },
  { hostname = "labnet-dns-02", target_node = "pve02", ip = "172.16.0.4/24", gw = "172.16.0.1" },
]
```

---

## Step-CA (Certificate Authority)

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `step-ca_root_password` | `string` | Yes (sensitive) | -- | Root password for the step-ca LXC container |
| `step-ca_eth0_ipv4_cidr` | `string` | Yes | -- | Static IP with CIDR notation for step-ca (e.g., `10.1.50.10/24`) |

Both are **auto-generated** by `setup.sh`.

### Example

```hcl
step-ca_root_password  = "secure-ca-password"
step-ca_eth0_ipv4_cidr = "10.1.50.10/24"
```

---

## Kasm Workspaces

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `kasm_version` | `string` | No | `"1.17.0.7f020d"` | Kasm Workspaces version to install |
| `kasm_admin_password` | `string` | No | `"changeme123"` | Kasm web admin password |

### Example

```hcl
kasm_version        = "1.17.0.7f020d"
kasm_admin_password = "secure-kasm-password"
```

---

## SSH

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `ssh_public_key_file` | `string` | No | `"/crypto/lab-deploy.pub"` | Path to the SSH public key used for VM/LXC access |

The SSH key pair is generated by `setup.sh` during initial setup and stored in the `crypto/` directory (git-ignored). The path uses `"/crypto/..."` because Terraform runs inside a Docker container where the project root is mounted.

!!! note "Docker Path Mapping"
    The default value `/crypto/lab-deploy.pub` refers to the path **inside the Docker container**. The `compose.yml` mounts the project's `crypto/` directory to `/crypto` in the container. You should not need to change this unless you are running Terraform outside of Docker Compose.

---

## Complete Example

A complete `terraform.tfvars` file (copy from `terraform/terraform.tfvars.example`):

```hcl
# Authentication
proxmox_api_url      = "https://10.1.50.210:8006/api2/json"
proxmox_api_token_id = "terraform@pam!terraform-access-token"
proxmox_api_token    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_api_username = "root@pam"
proxmox_api_password = "your-password"
proxmox_target_node  = "pve01"

# Network
network_interface_bridge = "vmbr0"
network_gateway_address  = "10.1.50.1"

# Storage
lxc_storage = "local-lvm"

# DNS
dns_postfix          = "mylab.lan"
dns_primary_ipv4     = "10.1.50.3"
pihole_admin_password = "secure-admin-password"
pihole_root_password  = "secure-root-password"

dns_main_nodes = [
  { hostname = "dns-01", target_node = "pve01", ip = "10.1.50.3/24", gw = "10.1.50.1" },
]

dns_labnet_nodes = []

# Step-CA
step-ca_root_password  = "secure-ca-password"
step-ca_eth0_ipv4_cidr = "10.1.50.10/24"

# Kasm
kasm_version        = "1.17.0.7f020d"
kasm_admin_password = "secure-kasm-password"

# Proxmox Cluster
proxmox_node_ips = {
  pve01 = "10.1.50.210"
}
```

---

## Next Steps

- [Packer Variables](packer-variables.md) -- Configure golden image builds
- [Module Reference](module-reference.md) -- Detailed module inputs and outputs
- [Cloud-Init Templates](cloudinit-templates.md) -- Understand first-boot configuration
