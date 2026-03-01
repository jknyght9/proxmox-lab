# Cloud-Init Templates

Cloud-init provides first-boot configuration for VMs provisioned by Terraform. Each VM module includes a cloud-init template that is rendered with Terraform variables, uploaded to the Proxmox host as a snippet, and attached to the VM via the `cicustom` parameter.

---

## How Cloud-Init Works in Proxmox Lab

```mermaid
graph LR
    TMPL["Template File<br/>(*.tmpl)"] -->|templatefile()| RENDER["Rendered YAML<br/>(local_file)"]
    RENDER -->|SSH upload| SNIPPET["Proxmox Snippet<br/>(/var/lib/vz/snippets/)"]
    SNIPPET -->|cicustom| VM["VM Boot<br/>(cloud-init)"]
```

1. **Template rendering** -- Terraform's `templatefile()` function substitutes HCL variables into the `.tmpl` file, producing a valid cloud-init YAML document.
2. **Snippet upload** -- A `null_resource` provisioner uploads the rendered file to the target Proxmox node at `/var/lib/vz/snippets/<hostname>-user-data.yml`.
3. **VM attachment** -- The `proxmox_vm_qemu` resource references the snippet via `cicustom = "user=local:snippets/<hostname>-user-data.yml"`.
4. **First boot** -- When the VM boots for the first time, cloud-init reads the user-data and executes the configuration.

!!! note "Snippet Storage"
    Snippets are stored on the Proxmox node's local storage at `/var/lib/vz/snippets/`. For multi-node clusters, each VM's cloud-init is uploaded to the specific Proxmox node where that VM will run, using the `node_ip_map` variable to determine the correct SSH target.

---

## Nomad Cloud-Init

**File:** `terraform/vm-nomad/cloudinit/nomad-user-data.tmpl`

This template configures each Nomad cluster node with user accounts, the Nomad agent configuration, certificate tooling, and DNS resolution.

### Template Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `hostname` | `vm_configs[*].name` | Node hostname (e.g., `nomad01`) |
| `ssh_authorized_keys` | `ssh_public_key_file` | SSH public key for access |
| `dns_postfix` | `var.dns_postfix` | Domain suffix (e.g., `mylab.lan`) |
| `dns_primary_ip` | `var.dns_primary_ip` | Pi-hole DNS server IP |
| `acme_dir` | Derived | ACME directory URL: `https://ca.<dns_postfix>/acme/acme/directory` |
| `sans` | Derived | TLS Subject Alternative Names: `<hostname>.<dns_postfix>` |
| `nomad_datacenter` | `var.nomad_datacenter` | Nomad datacenter name (default: `dc1`) |
| `nomad_region` | `var.nomad_region` | Nomad region name (default: `global`) |
| `nomad_bootstrap_expect` | Derived | Number of servers for bootstrap (equals node count) |
| `nomad_servers` | Derived | Comma-separated list of server FQDNs for `retry_join` |
| `gluster_mount` | `var.gluster_mount_path` | GlusterFS mount path (default: `/srv/gluster/nomad-data`) |

### Configuration Sections

#### User Accounts

```yaml
users:
  - name: labadmin
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - <ssh_public_key>
  - name: root
    ssh_authorized_keys:
      - <ssh_public_key>
```

Two accounts are created: `labadmin` (with passwordless sudo) and `root`. Both receive the project's SSH public key.

#### Packages

```yaml
packages: [curl, jq, socat, ca-certificates]
```

#### Nomad Configuration

The template writes `/etc/nomad.d/nomad.hcl` with the following key settings:

| Setting | Value | Purpose |
|---------|-------|---------|
| `datacenter` | `dc1` | Nomad datacenter identifier |
| `region` | `global` | Nomad region identifier |
| `server.enabled` | `true` | Node acts as a Nomad server |
| `server.bootstrap_expect` | `3` | Quorum size for leader election |
| `server_join.retry_join` | FQDNs of all nodes | DNS-based server discovery |
| `client.enabled` | `true` | Node also acts as a Nomad client |
| `client.host_volume "gluster-data"` | GlusterFS mount path | Shared storage volume for jobs |
| `plugin "docker".allow_privileged` | `true` | Enable privileged containers |
| `plugin "docker".volumes.enabled` | `true` | Enable Docker volume mounts |
| `consul` | Disabled | Consul integration is turned off |

#### Certificate Installation Script

The template writes `/root/nomad-cert-install.sh`, which uses acme.sh to request TLS certificates from the internal step-ca:

1. Sets the default CA to the internal ACME directory
2. Issues a certificate for `<hostname>.<dns_postfix>` with additional SANs
3. Installs the certificate to `/etc/nomad.d/tls/`

#### DNS Override

When `dns_primary_ip` is set (non-empty), the `runcmd` section configures systemd-resolved to use Pi-hole as the primary DNS server and creates a persistent netplan configuration at `/etc/netplan/99-dns-override.yaml`.

#### NTP Synchronization

The template enables systemd-timesyncd and waits up to 60 seconds for NTP synchronization before proceeding with remaining setup steps.

#### Nomad Service

Nomad is **enabled** but **not started** by cloud-init. The `setup.sh` script handles starting Nomad after GlusterFS is configured across the cluster.

```yaml
runcmd:
  # Only enable nomad - setup.sh will start it after GlusterFS is configured
  - systemctl enable nomad
```

---

## Kasm Cloud-Init

**File:** `terraform/vm-kasm/cloudinit/kasm-user-data.tmpl`

This template configures the Kasm Workspaces VM with the Kasm installer, swap space, certificate management, and automatic renewal.

### Template Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `hostname` | `vm_configs[*].name` | VM hostname (e.g., `kasm01`) |
| `ssh_authorized_keys` | `ssh_public_key_file` | SSH public key |
| `dns_postfix` | `var.dns_postfix` | Domain suffix |
| `acme_dir` | Derived | ACME directory URL |
| `sans` | Derived | SANs: `<hostname>.<dns_postfix> kasm.<dns_postfix>` |
| `kasm_download_url` | Derived | S3 download URL for Kasm tarball |
| `kasm_version` | `var.kasm_version` | Kasm release version |
| `kasm_admin_password` | `var.kasm_admin_password` | Admin password for Kasm web UI |

### Configuration Sections

#### User Accounts and Packages

Identical to the Nomad template: `labadmin` and `root` accounts with SSH keys, plus `curl`, `jq`, `socat`, and `ca-certificates` packages.

#### Kasm Certificate Script

The template creates `/root/kasm-install.sh`, which:

1. Stops the running Kasm instance
2. Uses acme.sh to issue a certificate from step-ca
3. Installs the certificate to `/opt/kasm/current/certs/`
4. Restarts Kasm

#### NTP Synchronization

Same as the Nomad template: enables systemd-timesyncd and waits for sync.

#### Swap Configuration

Creates a 4 GB swap file if one does not already exist:

```bash
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
```

#### Kasm Installation

Downloads and installs Kasm from the S3-hosted release tarball with retry logic (up to 5 attempts with exponential backoff):

```bash
curl -fsSLO <kasm_download_url>
tar -xf kasm_release_<version>.tar.gz
cd ~/kasm_release
bash install.sh --accept-eula --admin-password <password>
```

#### acme.sh Installation

Installs acme.sh if not already present:

```bash
curl -fsSL https://get.acme.sh | sh -s email=admin@<dns_postfix>
```

#### Certificate Renewal Cron

Sets up automatic certificate renewal:

1. Creates `/root/kasm-renew.sh` to restart Kasm after renewal
2. Installs the acme.sh cron job
3. Adds a cron entry to run certificate renewal at **3:00 AM daily**, executing the restart script on success

---

## Variable Injection Flow

Both templates follow the same variable injection pattern:

```mermaid
graph TD
    TFVARS["terraform.tfvars"] --> ROOT_MAIN["terraform/main.tf"]
    ROOT_MAIN -->|module inputs| MOD_MAIN["module/main.tf"]
    MOD_MAIN -->|templatefile()| TMPL["cloudinit/*.tmpl"]
    TMPL -->|rendered| YAML["*-user-data.yml"]
```

### Derived Values

Some template variables are computed from inputs rather than passed directly:

| Derived Variable | Formula | Example |
|------------------|---------|---------|
| `acme_dir` | `https://ca.${dns_postfix}/acme/acme/directory` | `https://ca.mylab.lan/acme/acme/directory` |
| `sans` | `${hostname}.${dns_postfix}` | `nomad01.mylab.lan` |
| `nomad_servers` | Joined FQDNs of all `vm_configs` entries | `"nomad01.mylab.lan","nomad02.mylab.lan","nomad03.mylab.lan"` |
| `nomad_bootstrap_expect` | `length(vm_configs)` | `3` |
| `kasm_download_url` | `https://kasm-static-content.s3.amazonaws.com/kasm_release_${kasm_version}.tar.gz` | Full S3 URL |

---

## Certificate Provisioning via acme.sh

Both VM modules use [acme.sh](https://github.com/acmesh-official/acme.sh) to obtain TLS certificates from the internal step-ca. The general flow is:

1. **acme.sh installation** -- Installed during cloud-init `runcmd` phase if not already present on the template
2. **CA configuration** -- `acme.sh --set-default-ca --server <acme_dir>` points acme.sh at the internal step-ca ACME endpoint
3. **Certificate issuance** -- `acme.sh --issue --alpn -d <fqdn>` requests a certificate using the ALPN (TLS-ALPN-01) challenge method
4. **Certificate installation** -- `acme.sh --install-cert` copies the key and fullchain to the service-specific directory

### Certificate Locations

| Service | Key Path | Certificate Path |
|---------|----------|-----------------|
| Nomad | `/etc/nomad.d/tls/nomad.key` | `/etc/nomad.d/tls/nomad.crt` |
| Kasm | `/opt/kasm/current/certs/kasm_nginx.key` | `/opt/kasm/current/certs/kasm_nginx.crt` |

!!! info "Certificate Duration"
    The step-ca ACME provisioner is configured with `defaultTLSCertDuration` and `maxTLSCertDuration` set to `2160h` (90 days). The acme.sh cron job handles automatic renewal before expiry.

---

## LXC Containers and Cloud-Init

The LXC modules (lxc-pihole and lxc-step-ca) do **not** use cloud-init templates. Instead, they use Terraform provisioners (`remote-exec`, `file`, `local-exec`) to configure containers after creation:

- **lxc-pihole** -- Uses `remote-exec` for direct SSH provisioning (external network) or `local-exec` with `pct exec` for SDN networks
- **lxc-step-ca** -- Uses `file` to upload CA files and `remote-exec` to install step-ca and configure the systemd service

This approach is used because LXC containers in Proxmox have limited cloud-init support compared to QEMU VMs.

---

## Next Steps

- [Nomad Cluster](../modules/nomad-cluster.md) -- How Nomad is configured post-boot
- [Kasm Workspaces](../modules/kasm.md) -- Kasm installation and access details
- [Step-CA](../modules/step-ca.md) -- Certificate Authority configuration
- [Terraform Variables](terraform-variables.md) -- All input variables
