# Accessing Services

This guide provides URLs and access information for all services in the Proxmox Lab.

## Service Directory

| Service | URL | Port | Credentials |
|---------|-----|------|-------------|
| **Proxmox VE** | `https://<proxmox-ip>:8006` | 8006 | root / your password |
| **Nomad UI** | `http://nomad01.mylab.lan:4646` | 4646 | No auth |
| **Vault** | `https://vault.mylab.lan` | 443 (via Traefik) | Root token in `crypto/vault-credentials.json` |
| **Vault Direct** | `http://nomad01:8200` | 8200 | Same as above |
| **Authentik** | `https://auth.mylab.lan` | 443 (via Traefik) | Admin account (created on first run) |
| **Authentik Direct** | `http://nomad01:9000` | 9000 | Same as above |
| **Traefik Dashboard** | `http://nomad01:8081` | 8081 | No auth (localhost only) |
| **Pi-hole** | `http://<dns-ip>/admin` | 80 | Admin password from terraform.tfvars |
| **Kasm Workspaces** | `https://kasm.mylab.lan` | 443 | Admin password from terraform.tfvars |
| **step-ca Health** | `https://ca.mylab.lan/health` | 443 | No auth (public endpoint) |

## Quick Access

### From Your Workstation

```bash
# Proxmox (after installing CA cert)
open https://<proxmox-ip>:8006

# Nomad UI
open http://nomad01.mylab.lan:4646

# Vault (via Traefik with TLS)
open https://vault.mylab.lan

# Authentik SSO
open https://auth.mylab.lan

# Pi-hole
open http://dns-01.mylab.lan/admin

# Kasm
open https://kasm.mylab.lan
```

### SSH Access

```bash
# Nomad nodes
ssh ubuntu@nomad01.mylab.lan
ssh ubuntu@nomad02.mylab.lan
ssh ubuntu@nomad03.mylab.lan

# Kasm
ssh ubuntu@kasm.mylab.lan

# LXC containers (via Proxmox host)
ssh root@<proxmox-ip>
pct enter 902  # step-ca
pct enter 910  # dns-01
```

## Nomad Services

### Accessing via Traefik

All Nomad services are accessible via Traefik with automatic TLS:

```bash
# HTTPS (recommended)
https://vault.mylab.lan
https://auth.mylab.lan

# HTTP (redirects to HTTPS)
http://vault.mylab.lan
```

### Direct Access

Services can also be accessed directly on nomad01:

```bash
# Vault
http://nomad01:8200

# Authentik
http://nomad01:9000

# Traefik API
http://nomad01:8081
```

### Short Names

Traefik accepts both FQDN and short names:

```bash
# Both work (if DNS configured)
https://vault.mylab.lan
https://vault
```

## Vault Access

### Web UI

1. Navigate to `https://vault.mylab.lan`
2. Select "Token" auth method
3. Enter root token from `crypto/vault-credentials.json`

### CLI Access

```bash
# Set environment
export VAULT_ADDR="http://nomad01:8200"
export VAULT_TOKEN=$(jq -r .root_token crypto/vault-credentials.json)

# Test access
vault status
vault kv list secret/
```

### Unseal After Restart

```bash
./setup.sh
# Select option 10: Unseal Vault

# Or manually
UNSEAL_KEY=$(jq -r .unseal_key crypto/vault-credentials.json)
curl -X PUT http://nomad01:8200/v1/sys/unseal \
  -d "{\"key\": \"$UNSEAL_KEY\"}"
```

## Authentik Access

### Initial Setup

First-time access requires creating admin account:

1. Navigate to `https://auth.mylab.lan/if/flow/initial-setup/`
2. Create admin account with email and password
3. Complete setup wizard

### Admin Interface

URL: `https://auth.mylab.lan/if/admin/`

Use the credentials you created during initial setup.

### User Portal

URL: `https://auth.mylab.lan/if/user/`

Regular users login here after admin configures authentication.

## DNS Management

### Pi-hole Admin

1. Navigate to `http://<dns-ip>/admin`
2. Click "Login"
3. Enter password from `pihole_admin_password` in terraform.tfvars

### Adding Local DNS Records

Pi-hole v6 uses TOML configuration:

```bash
# SSH to dns-01
pct enter 910

# Edit config
nano /etc/pihole/pihole.toml

# Add host record in [dns.hosts] section
[[dns.hosts]]
  domain = "newhost.mylab.lan"
  addr = "10.1.50.100"

# Restart FTL
pihole restartdns
```

Or use `./setup.sh` option 10 to rebuild all DNS records.

## Traefik Dashboard

### Accessing Dashboard

```bash
# Via SSH tunnel (recommended)
ssh -L 8081:localhost:8081 ubuntu@nomad01

# Then open in browser
open http://localhost:8081
```

### Dashboard Features

- HTTP routers and rules
- Services and backends
- Middleware configuration
- TLS certificates
- Access logs

### API Queries

```bash
# List all routers
curl http://nomad01:8081/api/http/routers | jq .

# List services
curl http://nomad01:8081/api/http/services | jq .

# TLS certificates
curl http://nomad01:8081/api/http/routers | jq '.[] | select(.tls) | {name, rule, certResolver: .tls.certResolver}'
```

## Certificate Authority

### Health Check

```bash
curl https://ca.mylab.lan/health

# Expected:
{"status":"ok"}
```

### Download Root Certificate

```bash
# From browser
open https://ca.mylab.lan/roots.pem

# Via curl
curl -k https://ca.mylab.lan/roots.pem -o root_ca.crt
```

### ACME Directory

```bash
curl https://ca.mylab.lan/acme/acme/directory | jq .
```

## Kasm Workspaces

### Admin Portal

1. Navigate to `https://kasm.mylab.lan/admin`
2. Login with admin credentials from terraform.tfvars

### User Portal

URL: `https://kasm.mylab.lan`

### Available Workspaces

Default workspaces (configured during deployment):
- Ubuntu Desktop
- Firefox Browser
- Chrome Browser

## Network Considerations

### DNS Configuration

For best experience, configure your workstation or router to use dns-01 as primary DNS:

```bash
# Router method (recommended)
Set primary DNS: <dns-01-ip>
Set secondary DNS: <dns-02-ip>

# Per-device (macOS)
System Preferences → Network → Advanced → DNS
Add: <dns-01-ip>

# Per-device (Linux)
Edit /etc/resolv.conf:
nameserver <dns-01-ip>
```

### Hosts File (Alternative)

If not using Pi-hole as DNS:

```bash
# macOS/Linux: /etc/hosts
# Windows: C:\Windows\System32\drivers\etc\hosts

10.1.50.114 nomad01 nomad01.mylab.lan
10.1.50.114 vault vault.mylab.lan
10.1.50.114 auth auth.mylab.lan
10.1.50.114 traefik traefik.mylab.lan
```

### Installing CA Certificate

To trust TLS certificates issued by step-ca:

=== "macOS"

    ```bash
    curl -k -o root_ca.crt https://ca.mylab.lan/roots.pem
    sudo security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain root_ca.crt
    ```

=== "Ubuntu/Debian"

    ```bash
    curl -k -o root_ca.crt https://ca.mylab.lan/roots.pem
    sudo cp root_ca.crt /usr/local/share/ca-certificates/
    sudo update-ca-certificates
    ```

=== "Windows"

    ```powershell
    Invoke-WebRequest -Uri "https://ca.mylab.lan/roots.pem" -OutFile root_ca.crt
    Import-Certificate -FilePath .\root_ca.crt -CertStoreLocation Cert:\LocalMachine\Root
    ```

## Troubleshooting

### Cannot Access Services

```bash
# Check DNS resolution
nslookup vault.mylab.lan <dns-01-ip>

# Check Nomad job is running
nomad job status vault

# Check Traefik routes
curl http://nomad01:8081/api/http/routers | jq '.[] | select(.name | contains("vault"))'
```

### Certificate Errors

```bash
# Install CA certificate (see above)

# Or accept self-signed for testing
curl -k https://vault.mylab.lan
```

### Service Unavailable

```bash
# Check job allocation
nomad alloc status $(nomad job status -short vault | grep running | awk '{print $1}')

# View logs
nomad alloc logs -job vault
```

### Vault is Sealed

```bash
./setup.sh
# Select option 10: Unseal Vault
```

## Next Steps

- [:octicons-arrow-right-24: Nomad Operations](nomad-operations.md)
- [:octicons-arrow-right-24: Vault Operations](vault-operations.md)
- [:octicons-arrow-right-24: DNS Management](dns-management.md)
- [:octicons-arrow-right-24: Troubleshooting](../troubleshooting/common-issues.md)
