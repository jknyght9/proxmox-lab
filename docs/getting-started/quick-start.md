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
    5. Run Proxmox post-installation configuration
    6. Create the labnet SDN
    7. Download and create VM/LXC templates
    8. Generate Certificate Authority certificates
    9. Deploy all services via Terraform
    10. Configure DNS records
    11. Install TLS certificates on Proxmox

## Step 5: Verify Deployment

After the script completes, verify your services are running:

### Check Proxmox UI

1. Open `https://<PROXMOX_IP>:8006` in your browser
2. You should see new VMs and containers:
   - `docker01`, `docker02`, `docker03` (VMs)
   - `kasm01` (VM)
   - `pihole-external`, `pihole-internal` (LXC)
   - `step-ca` (LXC)

### Test DNS Resolution

Configure your workstation to use pihole-external as DNS:

```bash
# Test DNS resolution
nslookup docker01.mylab.lan 10.1.50.3
```

Expected output:
```
Server:		10.1.50.3
Address:	10.1.50.3#53

Name:	docker01.mylab.lan
Address: 10.1.50.X
```

### Access Services

| Service | URL | Notes |
|---------|-----|-------|
| Proxmox | `https://<PROXMOX_IP>:8006` | Now has valid TLS cert |
| Pihole External | `http://10.1.50.3/admin` | DNS management |
| Kasm | `https://kasm.mylab.lan` | Remote desktops |
| Step-CA | `https://ca.mylab.lan/health` | Should return `{"status":"ok"}` |

## Step 6: Post-Deployment Tasks

### Initialize Docker Swarm

SSH to docker01 and initialize the swarm:

```bash
ssh -i crypto/lab-deploy labadmin@docker01.mylab.lan

# On docker01:
docker swarm init --advertise-addr <docker01_ip>

# Copy the join command output, then on docker02 and docker03:
docker swarm join --token <TOKEN> <docker01_ip>:2377
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

### Configure Your Router/Clients

For the best experience, configure your network to use pihole-external as the DNS server:

1. **Router method**: Set `10.1.50.3` as the DNS server in your router's DHCP settings
2. **Per-device method**: Configure each device to use `10.1.50.3` as its DNS server

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
    - Verify pihole-external is running: `pct status 900`
    - Check your workstation's DNS is set to the pihole IP
    - Try: `nslookup google.com 10.1.50.3`

## Next Steps

- [:octicons-arrow-right-24: Understand the architecture](../architecture/overview.md)
- [:octicons-arrow-right-24: Learn about DNS management](../operations/dns-management.md)
- [:octicons-arrow-right-24: Issue certificates for new services](../operations/certificate-operations.md)
- [:octicons-arrow-right-24: Deploy containers to Docker Swarm](../operations/docker-swarm-operations.md)
