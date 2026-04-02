# Quick Start Guide

This guide walks you through deploying Proxmox Lab step by step.

!!! info "Estimated Time"
    Complete deployment takes approximately **30-45 minutes**.

## Step 1: Clone the Repository

```bash
git clone https://github.com/jknyght9/proxmox-lab.git
cd proxmox-lab
```

## Step 2: Configure Packer Variables

Copy the example configuration and edit it:

```bash
cp packer/packer.auto.pkrvars.hcl.example packer/packer.auto.pkrvars.hcl
```

Edit `packer/packer.auto.pkrvars.hcl`, replacing `192.168.1.100` with **your Proxmox server's IP address**:

```hcl
# Proxmox connection (replace with YOUR Proxmox IP)
proxmox_url          = "https://192.168.1.100:8006/api2/json"
proxmox_node         = "pve"
proxmox_token_id     = "hashicorp@pam!hashicorp-token"
proxmox_token_secret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Template credentials (change these!)
root_password = "YourSecurePassword123!"
ssh_username  = "labadmin"
ssh_password  = "YourSecurePassword456!"

# DNS domain
dns_postfix = "mylab.lan"
```

!!! warning "Security"
    Use strong, unique passwords. These will be the default credentials for your VMs.

!!! tip "Replace Example IPs"
    Throughout this guide, `192.168.1.100` is used as a placeholder for your Proxmox server's IP address. Replace it with the actual IP of your Proxmox host. Find it by checking your router's admin page or running `hostname -I` on the Proxmox node.

!!! note "API Token"
    The `hashicorp@pam` user and API token are created automatically by `setup.sh` during Proxmox node setup. If you are running Packer manually outside of setup.sh, you will need to create this user and token yourself or use your own credentials.

## Step 3: Configure Terraform Variables

Copy the example configuration and edit it:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`, replacing `192.168.1.100` with **your Proxmox server's IP address**:

```hcl
# Proxmox API (replace with YOUR Proxmox IP)
proxmox_api_url      = "https://192.168.1.100:8006/api2/json"
proxmox_api_token_id = "hashicorp@pam!hashicorp-token"
proxmox_api_token    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_target_node  = "pve"

# Cluster nodes (replace with YOUR Proxmox IP)
proxmox_node_ips = {
  "pve" = "192.168.1.100"
}

# Network
network_interface_bridge = "vmbr0"
network_gateway_address  = "192.168.1.1"

# Pi-hole admin password
pihole_admin_password = "YourPiholePassword!"

# Step-CA
step-ca_root_password  = "YourStepCAPassword!"
step-ca_eth0_ipv4_cidr = "192.168.1.6/24"

# DNS domain
dns_postfix = "mylab.lan"

# Template storage (must be shared for clusters)
template_storage = "local"

# Kasm (optional)
kasm_admin_password = "YourKasmPassword!"
```

## Step 4: Run the Setup Script

Execute the automated setup:

```bash
./setup.sh <PROXMOX_IP> <PROXMOX_PASSWORD>
```

**Example:**

```bash
# Replace with YOUR Proxmox IP and root password
./setup.sh 192.168.1.100 MyProxmoxRootPassword
```

Alternatively, run the interactive menu:

```bash
./setup.sh
```

!!! note "What happens during setup"
    The script will:

    1. Check that Docker, jq, and sshpass are installed
    2. Generate SSH keys in `crypto/`
    3. Connect to Proxmox and install SSH keys
    4. Detect cluster nodes and configure networking
    5. Select storage and network bridge
    6. Run Proxmox node setup (SDN, templates, user accounts)
    7. **Phase 1**: Deploy LXC containers (DNS cluster, Step-CA) via Terraform
    8. **Phase 2**: Build Packer templates (Docker 9001, Nomad 9002)
    9. **Phase 3**: Deploy VMs (Nomad cluster, Kasm) via Terraform
    10. Setup GlusterFS and initialize the Nomad cluster
    11. Update DNS records and distribute CA certificates

## Step 5: Verify Deployment

After the script completes, verify your services are running:

### Check Proxmox UI

1. Open `https://<PROXMOX_IP>:8006` in your browser
2. You should see new VMs and containers:
   - `nomad01` (905), `nomad02` (906), `nomad03` (907) -- VMs
   - `kasm` (930) -- VM
   - `dns-01` (910), `dns-02` (911), `dns-03` (912) -- LXC
   - `labnet-dns-01` (920), `labnet-dns-02` (921) -- LXC
   - `step-ca` (902) -- LXC

### Test DNS Resolution

Configure your workstation to use dns-01 as its DNS server:

```bash
# Test DNS resolution
nslookup nomad01.mylab.lan <dns-01-ip>
```

Expected output:
```
Server:		192.168.1.3
Address:	192.168.1.3#53

Name:	nomad01.mylab.lan
Address: 192.168.1.x
```

### Access Core Services

These services are available immediately after setup:

| Service | URL | Notes |
|---------|-----|-------|
| Proxmox | `https://<PROXMOX_IP>:8006` | Now has valid TLS cert |
| Pi-hole | `http://<dns-01-ip>/admin` | DNS management |
| Step-CA | `https://ca.<domain>/health` | Should return `{"status":"ok"}` |
| Nomad | `http://<nomad01-ip>:4646` | Cluster management UI |
| Kasm | `https://kasm.<domain>` | Remote desktops |

## Step 6: Deploy Nomad Services

After the base infrastructure is running, deploy additional services using the setup menu. Run `./setup.sh` to access the interactive menu:

```
 7) Deploy Traefik               - Reverse proxy / load balancer
 8) Deploy Vault                 - Secrets management
 9) Deploy Authentik             - SSO / Identity Provider
16) Deploy Samba AD              - Active Directory Domain Controllers
17) Configure Authentik AD Sync  - AD -> Authentik user sync
```

### Deploy Traefik (Recommended First)

Traefik acts as the reverse proxy and handles TLS certificates for all Nomad services:

```bash
./setup.sh
# Select option 7: Deploy Traefik
```

After deployment, the Traefik dashboard is available at `http://<nomad01-ip>:8081/dashboard/`.

### Deploy Vault

Vault provides secrets management. It is initialized and unsealed automatically during deployment:

```bash
./setup.sh
# Select option 8: Deploy Vault
```

Vault credentials (unseal key, root token) are saved to `crypto/vault-credentials.json`. After deployment, access Vault at `https://vault.<domain>`.

### Deploy Authentik

Authentik provides SSO with OAuth2/OIDC, SAML, and LDAP support:

```bash
./setup.sh
# Select option 9: Deploy Authentik
```

After deployment, access Authentik at `https://auth.<domain>`.

!!! info "Service Pinning"
    All Nomad services (Traefik, Vault, Authentik, Samba AD) are pinned to **nomad01** for consistent DNS resolution and simplified routing.

### Post-Deployment Service Summary

| Service | URL | Notes |
|---------|-----|-------|
| Traefik | `http://<nomad01-ip>:8081/dashboard/` | Reverse proxy dashboard |
| Vault | `https://vault.<domain>` | Secrets management |
| Authentik | `https://auth.<domain>` | SSO / Identity Provider |

## Step 7: Install Root CA on Your Workstation

To trust certificates issued by your CA:

=== "macOS"

    ```bash
    curl -k -o proxmox-lab-ca.crt https://ca.mylab.lan/roots.pem
    sudo security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain proxmox-lab-ca.crt
    ```

=== "Ubuntu/Debian"

    ```bash
    curl -k -o proxmox-lab-ca.crt https://ca.mylab.lan/roots.pem
    sudo cp proxmox-lab-ca.crt /usr/local/share/ca-certificates/
    sudo update-ca-certificates
    ```

=== "Windows (PowerShell)"

    ```powershell
    Invoke-WebRequest -Uri "https://ca.mylab.lan/roots.pem" -OutFile proxmox-lab-ca.crt
    Import-Certificate -FilePath .\proxmox-lab-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
    ```

## Step 8: Configure Your Router/Clients

For the best experience, configure your network to use the DNS cluster:

1. **Router method**: Set your dns-01 IP as the primary DNS server in your router's DHCP settings
2. **Per-device method**: Configure each device to use your dns-01 IP as its DNS server

!!! tip "DNS Redundancy"
    You can configure dns-02 and dns-03 as secondary DNS servers on your router for failover. All nodes are synced via Gravity Sync.

## Setup Menu Reference

The full setup menu provides these options:

| Option | Action |
|--------|--------|
| 1 | New installation (full setup with SSH key generation) |
| 2 | New installation (skip SSH -- use existing keys) |
| 3 | Deploy all services (DNS, CA, Nomad, Kasm) |
| 4 | Deploy critical services (DNS and CA only) |
| 5 | Deploy Nomad only (requires critical services) |
| 6 | Deploy Kasm only (requires critical services + docker template) |
| 7 | Deploy Traefik |
| 8 | Deploy Vault |
| 9 | Deploy Authentik |
| 10 | Build DNS records |
| 11 | Regenerate CA |
| 12 | Update root certificates |
| 13 | Rollback (Terraform destroy) |
| 14 | Purge (Emergency -- direct VM/LXC destruction via SSH) |
| 15 | Purge entire deployment |
| 16 | Deploy Samba AD |
| 17 | Configure Authentik AD Sync |

## Troubleshooting

??? question "Script fails with 'sshpass not found'"
    Install sshpass:

    - macOS: `brew install hudochenkov/sshpass/sshpass`
    - Ubuntu: `sudo apt install sshpass`

??? question "Cannot connect to Proxmox"
    - Verify the IP address is correct
    - Ensure SSH is enabled on Proxmox
    - Check that port 22 is not blocked by a firewall

??? question "Terraform errors about existing resources"
    If you're re-running after a partial deployment:

    ```bash
    docker compose run terraform destroy
    ```

    Or use setup.sh menu option 13 (Rollback) to destroy Terraform-managed resources.

??? question "DNS not resolving"
    - Verify dns-01 is running: check in Proxmox UI or `pct status 910`
    - Check your workstation's DNS is set to the dns-01 IP
    - Try: `nslookup google.com <dns-01-ip>`
    - Rebuild DNS records using setup.sh menu option 10

??? question "Nomad cluster not forming"
    - Verify all three Nomad nodes are running in Proxmox
    - Check that DNS resolves `nomad01.<domain>`, `nomad02.<domain>`, `nomad03.<domain>`
    - Access the Nomad UI at `http://<nomad01-ip>:4646` to check node status
    - Check Nomad logs: `docker compose run --rm nomad node status`

??? question "Vault not responding after deployment"
    - Vault may need to be unsealed -- check `crypto/vault-credentials.json` for the unseal key
    - Verify Vault is scheduled on nomad01: `docker compose run --rm nomad job status vault`
    - Check Vault logs: `docker compose run --rm nomad alloc logs -job vault`

## Next Steps

- [:octicons-arrow-right-24: Understand the architecture](../architecture/overview.md)
- [:octicons-arrow-right-24: Learn about DNS management](../operations/dns-management.md)
- [:octicons-arrow-right-24: Issue certificates for new services](../operations/certificate-operations.md)
- [:octicons-arrow-right-24: Manage Nomad jobs](../operations/nomad-operations.md)
