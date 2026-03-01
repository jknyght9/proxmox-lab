# Authentik SSO

Authentik is deployed as a Nomad job to provide centralized authentication (SSO) across all services. It fetches secrets from Vault using Workload Identity Federation.

## Overview

| Property | Value |
|----------|-------|
| **Deployment Type** | Nomad Job |
| **Job File** | `nomad/jobs/authentik.nomad.hcl` |
| **Constraint** | Pinned to nomad01 |
| **Ports** | 9000 (HTTP), 9443 (HTTPS) |
| **Storage** | GlusterFS subdirectories |
| **Access** | https://auth.mylab.lan or http://nomad01:9000 |

## Architecture

Authentik consists of 4 containers in a single task group:

1. **PostgreSQL** - Database (port 5432)
2. **Redis** - Cache and message broker (port 6379)
3. **Server** - Web UI and API (port 9000)
4. **Worker** - Background task processing

All containers run on nomad01 and share network via host mode.

## Deployment

### Prerequisites

- Nomad cluster running
- Traefik deployed (for ingress)
- Vault deployed and unsealed
- Nomad-Vault WIF configured

### Deploy via setup.sh

```bash
./setup.sh
# Select option 9: Deploy Authentik SSO (on Nomad)
```

What happens:
1. Checks that Traefik and Vault are running
2. Creates storage directories on GlusterFS
3. Generates secrets (postgres password, secret key)
4. Stores secrets in Vault at `secret/data/authentik`
5. Deploys Authentik job to Nomad
6. Updates DNS records

### Manual Deployment

```bash
# Ensure secrets exist in Vault
vault kv put secret/authentik \
  postgres_password="..." \
  secret_key="..."

# Deploy job
nomad job run nomad/jobs/authentik.nomad.hcl
```

## Configuration

### Vault Integration

Job uses WIF to fetch secrets at runtime:

```hcl
vault {
  role        = "authentik"
  change_mode = "restart"
}

template {
  data = <<EOH
{{ with secret "secret/data/authentik" }}
AUTHENTIK_SECRET_KEY={{ .Data.data.secret_key }}
AUTHENTIK_POSTGRESQL__PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
EOH
  destination = "secrets/authentik.env"
  env         = true
}
```

### Storage Layout

```
/srv/gluster/nomad-data/authentik/
├── postgres/     # PostgreSQL data files
├── redis/        # Redis persistence
├── media/        # Uploaded files (logos, etc.)
├── templates/    # Custom templates
└── certs/        # Custom certificates
```

### Traefik Routing

```hcl
tags = [
  "traefik.http.routers.authentik.rule=Host(`auth.mylab.lan`) || Host(`auth`)",
  "traefik.http.routers.authentik.tls=true",
  "traefik.http.routers.authentik.tls.certresolver=step-ca",
]
```

## Initial Setup

### First-Time Configuration

1. Open `https://auth.mylab.lan/if/flow/initial-setup/`
2. Create admin account
3. Set admin email and password
4. Complete setup wizard

### Web UI

Access: `https://auth.mylab.lan/if/admin/`

Features:
- User and group management
- Application configuration (OAuth2, SAML, LDAP)
- Flow customization
- Policy management

## Operations

### Checking Status

```bash
# Job status
nomad job status authentik

# View logs
nomad alloc logs -job authentik -task server
nomad alloc logs -job authentik -task worker
nomad alloc logs -job authentik -task postgres
```

### Restarting Service

```bash
# Restart job (will fetch fresh secrets from Vault)
nomad job stop -purge authentik
nomad job run nomad/jobs/authentik.nomad.hcl
```

### Database Access

```bash
# SSH to nomad01
ssh ubuntu@nomad01

# Connect to PostgreSQL
psql -h 127.0.0.1 -U authentik -d authentik
# Password from Vault: vault kv get secret/authentik
```

## Integrating Applications

### OAuth2/OIDC Provider

1. In Authentik admin UI: Applications → Create
2. Set name and slug
3. Create Provider (OAuth2/OIDC)
4. Configure redirect URIs
5. Note Client ID and Secret
6. Configure application to use Authentik as provider

### SAML Provider

1. Create Application
2. Create SAML Provider
3. Download metadata XML
4. Configure application with metadata

### LDAP Outpost

1. Create LDAP Provider
2. Deploy LDAP Outpost (can be Nomad job)
3. Configure applications to use LDAP
4. Bind DN: `cn=<user>,ou=users,dc=ldap,dc=goauthentik,dc=io`

## Troubleshooting

### Service Won't Start

```bash
# Check Vault status
curl http://nomad01:8200/v1/sys/health

# Verify secrets exist
vault kv get secret/authentik

# Check allocation failures
nomad alloc status $(nomad job status -short authentik | grep failed | awk '{print $1}')
```

### Database Connection Errors

```bash
# Check PostgreSQL logs
nomad alloc logs -job authentik -task postgres

# Verify postgres is running
nomad alloc status $(nomad job status -short authentik | grep running | awk '{print $1}') | grep postgres
```

### Cannot Access Web UI

```bash
# Check Traefik routes
curl http://nomad01:8081/api/http/routers | jq '.[] | select(.name | contains("authentik"))'

# Test direct access
curl -I http://nomad01:9000/-/health/live/
```

## Security

### Secrets Management

- All secrets stored in Vault
- No secrets in job files or environment
- Secrets injected at runtime via WIF
- Automatic rotation when job restarts

### Network Security

- Runs on internal network only
- TLS via Traefik
- Database not exposed externally
- Redis not exposed externally

## Backup and Recovery

### Backup Data

```bash
# Backup PostgreSQL
ssh ubuntu@nomad01
pg_dump -h 127.0.0.1 -U authentik authentik > authentik-backup.sql

# Backup media files
sudo tar -czf authentik-media.tar.gz /srv/gluster/nomad-data/authentik/media/
```

### Restore Data

```bash
# Restore PostgreSQL
psql -h 127.0.0.1 -U authentik authentik < authentik-backup.sql

# Restore media files
sudo tar -xzf authentik-media.tar.gz -C /
```

## Next Steps

- [Authentik Documentation](https://goauthentik.io/docs/)
- [:octicons-arrow-right-24: Vault Operations](../operations/vault-operations.md)
- [:octicons-arrow-right-24: Nomad Operations](../operations/nomad-operations.md)
