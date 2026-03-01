# Pre-Flight Checklist

Complete these items before running `setup.sh`. Check off each item as you complete it.

## Workstation Requirements

- [ ] **Docker installed and running**

    ```bash
    docker --version
    # Expected: Docker version 24.x or later
    ```

- [ ] **Docker Compose available**

    ```bash
    docker compose version
    # Expected: Docker Compose version v2.x
    ```

- [ ] **sshpass installed**

    ```bash
    sshpass -V
    # Expected: sshpass version info
    ```

- [ ] **jq installed**

    ```bash
    jq --version
    # Expected: jq-1.x
    ```

---

## Proxmox Server Requirements

- [ ] **Proxmox VE 7.x or later installed**

    Check version in Proxmox web UI or via:
    ```bash
    pveversion
    ```

- [ ] **Root password known**

    You'll need this for the initial setup script.

- [ ] **SSH access enabled**

    Verify you can SSH to Proxmox:
    ```bash
    ssh root@<PROXMOX_IP>
    ```

- [ ] **Network bridge configured** (typically `vmbr0`)

    Check in Proxmox: **Node > Network**

- [ ] **Storage available**

    Check in Proxmox: **Datacenter > Storage**

    Note your storage names:

    - VM disk storage: ________________
    - Template/ISO storage: ________________

!!! tip "Cluster Template Storage"
    If running a Proxmox cluster, template storage must be shared across all nodes (e.g., NFS, Ceph). The `template_storage` variable in Terraform must point to this shared storage.

---

## Network Information Gathered

- [ ] **Proxmox server IP address** (or cluster node IPs)

    IP: ________________

- [ ] **Network gateway address**

    Gateway: ________________

- [ ] **Reserved IPs for DNS cluster** (one per Proxmox node, up to 3)

    !!! warning "Must be static IPs outside your DHCP range"

    | Node | VMID | IP |
    |------|------|----|
    | dns-01 | 910 | ________________ |
    | dns-02 | 911 | ________________ |
    | dns-03 | 912 | ________________ |

- [ ] **Reserved IP for Step-CA**

    !!! warning "Must be outside DHCP range"

    | Node | VMID | IP |
    |------|------|----|
    | step-ca | 902 | ________________ |

- [ ] **DNS domain suffix chosen**

    Example: `mylab.lan`, `home.lab`, `lab.local`

    Domain: ________________

- [ ] **Labnet SDN range planned** (optional, for internal network)

    Default example: `172.16.0.0/24`

    Range: ________________

---

## API Token (Handled Automatically)

!!! info "Automatic Token Creation"
    The `setup.sh` script automatically creates a `hashicorp@pam` user and API token during Proxmox node setup. You do **not** need to create these manually.

    If you prefer to create credentials manually (e.g., for running Packer/Terraform outside of setup.sh), follow the steps below. Otherwise, skip this section.

??? note "Manual API Token Creation (Optional)"

    - [ ] **Create user "hashicorp"**

        Proxmox: **Datacenter > Permissions > Users > Add**

        - Username: `hashicorp`
        - Realm: `pam` (Linux PAM)

    - [ ] **Create API token**

        Proxmox: **Datacenter > Permissions > API Tokens > Add**

        - User: `hashicorp@pam`
        - Token ID: `hashicorp-token`
        - Privilege Separation: **Unchecked**

        !!! danger "Save the token secret!"
            The token secret is only shown once. Copy it immediately.

        Token ID: ________________
        Token Secret: ________________

    - [ ] **Assign permissions**

        Proxmox: **Datacenter > Permissions > Add > User Permission**

        - Path: `/`
        - User: `hashicorp@pam`
        - Role: `Administrator`

---

## Configuration Files Prepared

- [ ] **Packer configuration created**

    ```bash
    cp packer/packer.auto.pkrvars.hcl.example packer/packer.auto.pkrvars.hcl
    ```

    Edit and fill in all values:
    ```bash
    nano packer/packer.auto.pkrvars.hcl
    ```

- [ ] **Terraform configuration created**

    ```bash
    cp terraform/terraform.tfvars.example terraform/terraform.tfvars
    ```

    Edit and fill in all values:
    ```bash
    nano terraform/terraform.tfvars
    ```

---

## Configuration Values Reference

Use this as a reference when filling in your configuration files:

### packer.auto.pkrvars.hcl

| Variable | Description | Your Value |
|----------|-------------|------------|
| `proxmox_url` | Proxmox API URL | `https://IP:8006/api2/json` |
| `proxmox_node` | Proxmox node name | |
| `proxmox_token_id` | API token ID | `hashicorp@pam!hashicorp-token` |
| `proxmox_token_secret` | API token secret | |
| `root_password` | VM root password | |
| `ssh_username` | Default SSH user | `labadmin` |
| `ssh_password` | SSH user password | |
| `dns_postfix` | DNS domain | |

### terraform.tfvars

| Variable | Description | Your Value |
|----------|-------------|------------|
| `proxmox_api_url` | Proxmox API URL | `https://IP:8006/api2/json` |
| `proxmox_api_token_id` | API token ID | `hashicorp@pam!hashicorp-token` |
| `proxmox_api_token` | API token secret | |
| `proxmox_target_node` | Target node name | |
| `proxmox_node_ips` | Map of node names to IPs | `{ "pve" = "10.1.50.2" }` |
| `network_interface_bridge` | Network bridge | `vmbr0` |
| `network_gateway_address` | Gateway IP | |
| `pihole_admin_password` | Pi-hole web admin password | |
| `step-ca_root_password` | Step-CA container password | |
| `step-ca_eth0_ipv4_cidr` | Step-CA IP with CIDR | `x.x.x.x/24` |
| `dns_postfix` | DNS domain | |
| `template_storage` | Storage for Packer templates | `local` |
| `kasm_admin_password` | Kasm admin password | |

---

## VMID Reference

For planning and verification:

| VMID | Component |
|------|-----------|
| 902 | Step-CA (Certificate Authority) |
| 905-907 | Nomad cluster (nomad01-03) |
| 910-912 | Main DNS cluster (dns-01, dns-02, dns-03) |
| 920-921 | Labnet DNS (labnet-dns-01, labnet-dns-02) |
| 930 | Kasm Workspaces |
| 9001 | Docker Packer template |
| 9002 | Nomad Packer template |
| 9999 | Ubuntu base template |

---

## Final Verification

- [ ] **All configuration files have valid values** (no placeholders)
- [ ] **Passwords are strong and unique**
- [ ] **IP addresses are correct and available**
- [ ] **You have the Proxmox root password ready**
- [ ] **Sufficient resources available** (28 cores, 42 GB RAM, 428 GB disk at maximum)

---

## Ready to Deploy!

Once all items are checked, you're ready to run:

```bash
./setup.sh <PROXMOX_IP> <PROXMOX_ROOT_PASSWORD>
```

[:octicons-arrow-right-24: Continue to Quick Start Guide](quick-start.md)
