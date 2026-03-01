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

Edit `packer/packer.auto.pkrvars.hcl`:

```hcl
# Proxmox connection
proxmox_url          = "https://10.1.50.2:8006/api2/json"
proxmox_node         = "pve"
proxmox_token_id     = "terraform@pam!terraform-token"
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

## Step 3: Configure Terraform Variables

Copy the example configuration and edit it:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:

```hcl
# Proxmox API
proxmox_api_url      = "https://10.1.50.2:8006/api2/json"
proxmox_api_token_id = "terraform@pam!terraform-token"
proxmox_api_token    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_target_node  = "pve"

# Network
network_interface_bridge = "vmbr0"
network_gateway_address  = "10.1.50.1"

# Pihole (use static IPs outside your DHCP range)
pihole_root_password  = "YourPiholePassword!"
pihole_eth0_ipv4_cidr = "10.1.50.3/24"

# Step-CA
step-ca_root_password  = "YourStepCAPassword!"
step-ca_eth0_ipv4_cidr = "10.1.50.4/24"

# DNS domain
dns_postfix = "mylab.lan"

# Kasm (optional - change default password)
kasm_admin_password = "YourKasmPassword!"
```

## Step 4: Run the Setup Script

Execute the automated setup:

```bash
./setup.sh <PROXMOX_IP> <PROXMOX_PASSWORD>
```

**Example:**

```bash
./setup.sh 10.1.50.2 MyProxmoxRootPassword
```

!!! note "What happens during setup"
    The script will:

    1. Check that Docker, jq, and sshpass are installed
    2. Generate SSH keys in `crypto/`
    3. Connect to your Proxmox server
    4. Install SSH keys for passwordless access
    5. Detect cluster topology and configure networking
    6. Select shared storage and network bridge
    7. Create the labnet SDN (optional)
    8. Build Packer templates (Docker, Nomad)
    9. Deploy critical services (DNS cluster, step-ca)
    10. Deploy Nomad cluster with GlusterFS
    11. Deploy Nomad jobs (Traefik, Vault, Authentik)
    12. Configure Vault WIF integration
    13. Update DNS records for all services
    14. Install TLS certificates on Proxmox

## Step 5: Verify Deployment

After the script completes, verify your services are running:

### Check Proxmox UI

1. Open `https://<PROXMOX_IP>:8006` in your browser
2. You should see new VMs and containers:
   - `nomad01`, `nomad02`, `nomad03` (VMs)
   - `kasm01` (VM)
   - `dns-01`, `dns-02`, `dns-03` (LXC - main DNS)
   - `labnet-dns-01`, `labnet-dns-02` (LXC - SDN DNS)
   - `step-ca` (LXC)

### Test DNS Resolution

Configure your workstation to use the primary DNS server:

```bash
# Test DNS resolution (replace with your dns-01 IP)
nslookup nomad01.mylab.lan <dns-01-ip>
```

Expected output:
```
Server:		<dns-01-ip>
Address:	<dns-01-ip>#53

Name:	nomad01.mylab.lan
Address: <nomad01-ip>
```

### Access Services

| Service | URL | Notes |
|---------|-----|-------|
| Proxmox | `https://<PROXMOX_IP>:8006` | Now has valid TLS cert |
| DNS Cluster | `http://<dns-ip>/admin` | Pi-hole management |
| Nomad UI | `http://nomad01.mylab.lan:4646` | Cluster management |
| Vault | `https://vault.mylab.lan` | Secrets manager (via Traefik) |
| Authentik | `https://auth.mylab.lan` | SSO/Identity provider |
| Traefik | `http://nomad01.mylab.lan:8081` | Dashboard (API) |
| Kasm | `https://kasm.mylab.lan` | Remote desktops |
| Step-CA | `https://ca.mylab.lan/health` | Should return `{"status":"ok"}` |

## Step 6: Post-Deployment Tasks

### Verify Nomad Cluster

SSH to nomad01 and check cluster status:

```bash
ssh -i crypto/lab-deploy ubuntu@nomad01.mylab.lan

# On nomad01:
nomad server members
nomad node status
nomad job status
```

Expected output shows 3 servers in the cluster and running jobs (traefik, vault, authentik).

### Unseal Vault (if needed)

If Vault is sealed after restart:

```bash
# From your workstation
./setup.sh
# Select option 10: Unseal Vault
```

Or manually unseal:

```bash
# Unseal key is stored in crypto/vault-credentials.json
curl -X PUT http://nomad01:8200/v1/sys/unseal \
  -d '{"key": "<unseal-key-from-file>"}'
```

### Install Root CA on Your Workstation

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

### Configure Authentik (First Time)

Access Authentik and create your admin account:

```bash
# Open in browser
https://auth.mylab.lan/if/flow/initial-setup/
```

Follow the wizard to:
1. Create admin account
2. Set admin password
3. Configure authentication flows

### Configure Your Router/Clients

For the best experience, configure your network to use the primary DNS as the DNS server:

1. **Router method**: Set `<dns-01-ip>` as primary DNS in your router's DHCP settings
2. **Per-device method**: Configure each device to use `<dns-01-ip>` as its DNS server
3. **Secondary DNS**: Optionally add `<dns-02-ip>` as secondary DNS

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
    cd terraform
    docker compose run terraform destroy
    ```

    Then run `setup.sh` again.

??? question "DNS not resolving"
    - Verify dns-01 is running: `pct status 910`
    - Check your workstation's DNS is set to the dns-01 IP
    - Try: `nslookup google.com <dns-01-ip>`

??? question "Vault is sealed"
    Vault seals itself on restart for security. Unseal it:

    ```bash
    # Use setup.sh menu option 10, or manually:
    curl -X PUT http://nomad01:8200/v1/sys/unseal \
      -d '{"key": "<key-from-crypto/vault-credentials.json>"}'
    ```

??? question "Nomad jobs not running"
    Check job status and logs:

    ```bash
    nomad job status
    nomad alloc logs -job <job-name>
    ```

## Next Steps

- [:octicons-arrow-right-24: Understand the architecture](../architecture/overview.md)
- [:octicons-arrow-right-24: Learn about DNS management](../operations/dns-management.md)
- [:octicons-arrow-right-24: Manage Nomad jobs](../operations/nomad-operations.md)
- [:octicons-arrow-right-24: Manage Vault secrets](../operations/vault-operations.md)
- [:octicons-arrow-right-24: Issue certificates for new services](../operations/certificate-operations.md)
