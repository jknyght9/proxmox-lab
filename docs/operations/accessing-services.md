# Accessing Services

This page provides a consolidated reference for reaching every service deployed by Proxmox Lab, including URLs, ports, and default credential locations.

---

## Service URL Reference

| Service | URL | Port | Protocol |
|---------|-----|------|----------|
| **Proxmox VE** | `https://<proxmox-ip>:8006` | 8006 | HTTPS |
| **Pi-hole** | `http://<dns-ip>/admin` | 80 | HTTP |
| **Step-CA** | `https://ca.<domain>/health` | 443 | HTTPS |
| **Nomad UI** | `http://<nomad01-ip>:4646` | 4646 | HTTP |
| **Traefik Dashboard** | `http://<nomad01-ip>:8081/dashboard/` | 8081 | HTTP |
| **Vault UI** | `https://vault.<domain>` or `http://<nomad01-ip>:8200` | 8200 | HTTPS via Traefik or HTTP direct |
| **Authentik** | `https://auth.<domain>` | 443 | HTTPS via Traefik |
| **Kasm Workspaces** | `https://kasm.<domain>` | 443 | HTTPS |

!!! tip "Replace placeholders"
    - `<proxmox-ip>` -- your Proxmox host IP (e.g., `192.168.1.100`)
    - `<dns-ip>` -- one of the Pi-hole LXC IPs (e.g., `192.168.1.10`)
    - `<nomad01-ip>` -- the first Nomad node IP (e.g., `192.168.1.50`)
    - `<domain>` -- your configured `dns_postfix` (e.g., `mylab.lan`)

---

## Proxmox VE

Access the Proxmox web interface at `https://<proxmox-ip>:8006`.

- **Username**: `root` (or any user configured in Proxmox)
- **Password**: the password you provided during `setup.sh` or your Proxmox root password
- **Realm**: PAM or PVE, depending on your Proxmox configuration

!!! note
    The Proxmox web UI uses a self-signed certificate by default. Your browser will display a security warning that you can safely accept for your lab environment.

---

## Pi-hole DNS

Access the Pi-hole admin dashboard at `http://<dns-ip>/admin`.

- **Password**: the `pihole_admin_password` value set in `terraform/terraform.tfvars`
- **Multiple instances**: each Pi-hole LXC (dns-01, dns-02, dns-03) runs its own admin interface on the same port

To check which Pi-hole instances are deployed, refer to `hosts.json` or run setup.sh menu option 10 to view DNS records.

---

## Step-CA (Certificate Authority)

The Step-CA health endpoint is available at `https://ca.<domain>/health`.

- **No web UI**: Step-CA is a headless certificate authority
- **Root CA certificate**: stored locally in `crypto/` after deployment
- **Health check**: a `200 OK` response from `/health` confirms the service is running

---

## Nomad UI

Access the Nomad web UI at `http://<nomad01-ip>:4646`.

- **No authentication by default**: the Nomad UI is open when ACLs are not enabled
- **Job management**: view running jobs, allocations, and task logs
- **Topology view**: see cluster node status and resource usage

The Nomad UI provides:

- **Jobs** -- list all deployed jobs and their status
- **Allocations** -- inspect individual task allocations and their health
- **Servers** -- view server members and leader election status
- **Clients** -- check node status and available resources

---

## Traefik Dashboard

Access the Traefik dashboard at `http://<nomad01-ip>:8081/dashboard/`.

!!! warning "Trailing slash required"
    The URL must end with `/dashboard/` (including the trailing slash). Without it, Traefik returns a 404.

- **No authentication by default**: the dashboard is read-only
- **HTTP Routers**: view all configured routing rules
- **HTTP Services**: see discovered Nomad services and their health
- **Entrypoints**: check which ports Traefik is listening on

The Traefik API is also available at `http://<nomad01-ip>:8081/api/` for programmatic access:

```bash
# List all HTTP routers
curl http://<nomad01-ip>:8081/api/http/routers | jq .

# List all HTTP services
curl http://<nomad01-ip>:8081/api/http/services | jq .
```

---

## Vault

Access the Vault UI through Traefik at `https://vault.<domain>` or directly at `http://<nomad01-ip>:8200`.

### Credentials

Vault credentials are stored in `crypto/vault-credentials.json` after initial setup:

```json
{
  "unseal_key": "<base64-encoded-key>",
  "root_token": "hvs.xxxxxxxxxxxx",
  "vault_address": "http://192.168.1.50:8200",
  "initialized_at": "2026-02-22T12:00:00Z"
}
```

- **Root token**: use `root_token` to log in to the Vault UI (select "Token" as the authentication method)
- **Unseal key**: needed to unseal Vault after a restart (see [Backup & Recovery](backup-recovery.md))

!!! danger "Protect these credentials"
    The `crypto/vault-credentials.json` file is gitignored for a reason. Never commit this file or share the unseal key and root token outside of secure channels.

### Checking Vault Status

```bash
# Via Docker Compose
docker compose run --rm nomad alloc logs -job vault

# Direct API check
curl -s http://<nomad01-ip>:8200/v1/sys/health | jq .
```

---

## Authentik

Access Authentik at `https://auth.<domain>`.

- **Initial admin user**: `akadmin`
- **Password**: stored in Vault at `secret/data/authentik` (the `authentik_secret_key` or bootstrap password configured during deployment)
- **Routed through Traefik**: Authentik is accessed via HTTPS through the Traefik reverse proxy

Authentik provides:

- **Admin interface**: `https://auth.<domain>/if/admin/` for system configuration
- **User interface**: `https://auth.<domain>/if/user/` for end-user self-service
- **OAuth2/OIDC endpoints**: for application integration

---

## Kasm Workspaces

Access Kasm at `https://kasm.<domain>`.

- **Default admin user**: `admin@kasm.local`
- **Password**: set during the Kasm installation process
- **Direct HTTPS**: Kasm manages its own TLS certificate via acme.sh

---

## Service Discovery via DNS

All service hostnames are registered in Pi-hole as local DNS records. The setup process (menu option 10) automatically configures:

| DNS Record | Points To |
|-----------|-----------|
| `vault.<domain>` | nomad01 IP |
| `auth.<domain>` | nomad01 IP |
| `traefik.<domain>` | nomad01 IP |
| `ca.<domain>` | step-ca LXC IP |

If a service hostname is not resolving, see [DNS Management](dns-management.md) or run setup.sh menu option 10 to rebuild DNS records.

---

## Docker Compose CLI Tools

Several services are managed through Docker Compose wrappers from the project root:

```bash
# Serve documentation locally (port 8000)
docker compose up mkdocs

# Packer commands
docker compose run packer <command>

# Terraform commands
docker compose run terraform <command>

# Nomad CLI
docker compose run --rm nomad <command>
```

These wrappers handle container networking and credential mounting automatically. See [Nomad Operations](nomad-operations.md) for detailed Nomad CLI usage.
