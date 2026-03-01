# Packer Variables

Packer variables control the golden image build process. They are defined in `packer/variables.pkr.hcl` and values are provided through `packer/packer.auto.pkrvars.hcl`.

!!! info "Setup"
    Copy the example file to get started:
    ```bash
    cp packer/packer.auto.pkrvars.hcl.example packer/packer.auto.pkrvars.hcl
    ```

---

## Proxmox Connection

These variables configure how Packer connects to your Proxmox API to create templates.

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `proxmox_url` | `string` | Yes | -- | Proxmox API URL (e.g., `https://192.168.1.200:8006/api2/json`) |
| `proxmox_node` | `string` | Yes | -- | Proxmox node name where templates will be created (e.g., `pve01`) |
| `proxmox_token_id` | `string` | Yes | -- | API token ID for authentication |
| `proxmox_token_secret` | `string` | Yes | -- | API token secret value |

### Example

```hcl
proxmox_url          = "https://192.168.1.200:8006/api2/json"
proxmox_node         = "pve01"
proxmox_token_id     = "packer@pam!packer-access-token"
proxmox_token_secret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

## Template Credentials

Credentials baked into the Packer templates. These are used during the build process for SSH access and as default accounts on the resulting template.

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `root_password` | `string` | No | `"changeme123"` | Root password for the template |
| `ssh_username` | `string` | No | `"labadmin"` | SSH username created in the template |
| `ssh_password` | `string` | No | `"changeme123"` | SSH password for the template user |
| `ssh_private_key_file` | `string` | No | `"/crypto/lab-deploy"` | Path to the SSH private key (inside Docker container) |
| `ssh_public_key_file` | `string` | No | `"/crypto/lab-deploy.pub"` | Path to the SSH public key (inside Docker container) |

!!! warning "Default Passwords"
    The default passwords are `changeme123`. These should be changed for any environment beyond local testing. When VMs are cloned from these templates, cloud-init overwrites access credentials, so template passwords primarily matter during the Packer build process itself.

!!! note "Docker Path Mapping"
    The `ssh_private_key_file` default value `/crypto/lab-deploy` refers to the path **inside the Packer Docker container**. The `compose.yml` mounts the project's `crypto/` directory to `/crypto`. Do not change this unless running Packer outside Docker Compose.

---

## DNS

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `dns_postfix` | `string` | Yes | -- | Domain suffix embedded in templates (e.g., `mylab.lan`) |

This value is used during the template build to configure the base domain for services. It should match the `dns_postfix` used in your Terraform variables.

---

## Template Storage

These variables control where Packer stores the resulting VM templates on your Proxmox storage.

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `template_storage` | `string` | No | `"local"` | Proxmox storage pool for template disks |
| `template_storage_type` | `string` | No | `"lvm"` | Storage backend type |

### Storage Types

| Type | Description | Use Case |
|------|-------------|----------|
| `lvm` | Local LVM thin provisioning | Single-node setups |
| `dir` | Directory-based storage | Simple local storage |
| `nfs` | Network File System | Shared storage across nodes |
| `rbd` | Ceph RADOS Block Device | Ceph distributed storage |
| `cephfs` | Ceph File System | Ceph file-level storage |

!!! tip "Multi-Node Clusters"
    For Proxmox clusters with multiple nodes, use shared storage (`nfs`, `rbd`, `cephfs`) so that templates are accessible from all nodes. Single-node setups can use `local` or `local-lvm`.

---

## Template Naming

These variables set the VM IDs and names for the two Packer templates.

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `docker_name` | `string` | No | `"docker-template"` | Name of the Docker base template |
| `docker_vmid` | `number` | No | `9001` | VM ID for the Docker base template |
| `nomad_name` | `string` | No | `"nomad-template"` | Name of the Nomad template |
| `nomad_vmid` | `number` | No | `9002` | VM ID for the Nomad template |

Both templates are cloned from the Ubuntu Server 24.04 base template (VMID `9999`), which must already exist in Proxmox.

### Template Hierarchy

```
Ubuntu Server 24.04 (VMID 9999)
  |
  +-- docker-template (VMID 9001)
  |     Ubuntu + Docker + GlusterFS client + acme.sh
  |     Used by: vm-kasm module
  |
  +-- nomad-template (VMID 9002)
        Docker template + Nomad + Consul
        Used by: vm-nomad module
```

---

## Complete Example

A complete `packer.auto.pkrvars.hcl` file:

```hcl
# Proxmox connection
proxmox_url          = "https://192.168.1.200:8006/api2/json"
proxmox_node         = "pve01"
proxmox_token_id     = "packer@pam!packer-access-token"
proxmox_token_secret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Template credentials
root_password        = "changeme123"
ssh_username         = "labadmin"
ssh_password         = "changeme123"
ssh_private_key_file = "/crypto/lab-deploy"

# DNS
dns_postfix = "mylab.lan"

# Storage (use shared storage for multi-node clusters)
template_storage      = "local"
template_storage_type = "lvm"
```

---

## Building Templates

Templates are built using Docker Compose to run Packer inside a container:

```bash
# Initialize Packer plugins
docker compose run packer init .

# Validate configuration
docker compose run packer validate .

# Build the Docker base template (must be built first)
docker compose run packer build build_docker.pkr.hcl

# Build the Nomad template (depends on Docker template)
docker compose run packer build build_nomad.pkr.hcl
```

!!! important "Build Order"
    The Docker template (`9001`) must be built before the Nomad template (`9002`), since the Nomad template clones from the Docker template. Both require the Ubuntu Server 24.04 base template (`9999`) to already exist in Proxmox.

---

## Source Configuration

Packer source definitions live in separate files and reference these variables:

- **`sources_linux_docker.pkr.hcl`** -- Defines the `proxmox-clone.ubuntu-docker` source, cloning from VM `9999`, producing VMID `9001`. Uses 2 cores, 4 GB RAM, virtio NIC on `vmbr0`.

- **`sources_linux_nomad.pkr.hcl`** -- Defines the `proxmox-clone.ubuntu-nomad` source, cloning from VM `9999`, producing VMID `9002`. Same hardware configuration as the Docker source.

Both sources use the `proxmox-clone` builder type, which creates a new VM by cloning an existing template and then running provisioners on it.

---

## Next Steps

- [Terraform Variables](terraform-variables.md) -- Configure infrastructure provisioning
- [Module Reference](module-reference.md) -- Understand what each module deploys
- [Cloud-Init Templates](cloudinit-templates.md) -- First-boot configuration for VMs
