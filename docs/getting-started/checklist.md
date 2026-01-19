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

- [ ] **Proxmox VE 8.x or later installed**

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
    - Template storage: ________________

---

## Network Information Gathered

- [ ] **Proxmox server IP address**

    IP: ________________

- [ ] **Network gateway address**

    Gateway: ________________

- [ ] **Reserved IP for pihole-external**

    !!! warning "Must be outside DHCP range"

    IP: ________________

- [ ] **Reserved IP for step-ca**

    !!! warning "Must be outside DHCP range"

    IP: ________________

- [ ] **DNS domain suffix chosen**

    Example: `mylab.lan`, `home.lab`, `lab.local`

    Domain: ________________

---

## API Token Created (Optional but Recommended)

Creating an API token is more secure than using root credentials:

- [ ] **Create user "terraform"**

    Proxmox: **Datacenter > Permissions > Users > Add**

    - Username: `terraform`
    - Realm: `pam` (Linux PAM)

- [ ] **Create API token**

    Proxmox: **Datacenter > Permissions > API Tokens > Add**

    - User: `terraform@pam`
    - Token ID: `terraform-token`
    - Privilege Separation: **Unchecked** (for simplicity)

    !!! danger "Save the token secret!"
        The token secret is only shown once. Copy it immediately.

    Token ID: ________________
    Token Secret: ________________

- [ ] **Assign permissions**

    Proxmox: **Datacenter > Permissions > Add > User Permission**

    - Path: `/`
    - User: `terraform@pam`
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
| `proxmox_token_id` | API token ID | `user@pam!token-name` |
| `proxmox_token_secret` | API token secret | |
| `root_password` | VM root password | |
| `ssh_username` | Default SSH user | `labadmin` |
| `ssh_password` | SSH user password | |
| `dns_postfix` | DNS domain | |

### terraform.tfvars

| Variable | Description | Your Value |
|----------|-------------|------------|
| `proxmox_api_url` | Proxmox API URL | `https://IP:8006/api2/json` |
| `proxmox_api_token_id` | API token ID | `user@pam!token-name` |
| `proxmox_api_token` | API token secret | |
| `proxmox_target_node` | Target node name | |
| `network_interface_bridge` | Network bridge | `vmbr0` |
| `network_gateway_address` | Gateway IP | |
| `pihole_root_password` | Pihole container password | |
| `pihole_eth0_ipv4_cidr` | Pihole IP with CIDR | `x.x.x.x/24` |
| `step-ca_root_password` | Step-CA container password | |
| `step-ca_eth0_ipv4_cidr` | Step-CA IP with CIDR | `x.x.x.x/24` |
| `dns_postfix` | DNS domain | |
| `kasm_admin_password` | Kasm admin password | |

---

## Final Verification

- [ ] **All configuration files have valid values** (no placeholders)
- [ ] **Passwords are strong and unique**
- [ ] **IP addresses are correct and available**
- [ ] **You have the Proxmox root password ready**

---

## Ready to Deploy!

Once all items are checked, you're ready to run:

```bash
./setup.sh <PROXMOX_IP> <PROXMOX_ROOT_PASSWORD>
```

[:octicons-arrow-right-24: Continue to Quick Start Guide](quick-start.md)
