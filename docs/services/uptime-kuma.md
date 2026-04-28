# Uptime Kuma

Uptime Kuma is a self-hosted service health monitoring tool with a clean web UI. It monitors service endpoints and provides status pages, alerting, and uptime statistics.

## Overview

| Property | Value |
|----------|-------|
| **Nomad Job** | `uptime-kuma` |
| **Image** | `louislam/uptime-kuma:2` |
| **Node** | Pinned to `nomad01` |
| **Port** | 3001 |
| **Storage** | `/srv/gluster/nomad-data/uptime-kuma/` (GlusterFS) |
| **Embedded DB** | MariaDB (v2 — not compatible with v1 SQLite data) |

## Deployment

Select option 5 from the setup menu:

```bash
./setup.sh
# 5) Uptime Kuma (monitoring)
```

## First-Time Setup

Uptime Kuma does not support environment variable-based admin provisioning. After deployment:

1. Browse to `https://status.<dns-suffix>`
2. Create the first admin account
3. Configure monitors for your services

!!! note "Authentik protection"
    The status page is protected by Authentik forward auth when accessed through Traefik. After you create an admin account, you can optionally disable the built-in auth: Settings > Security > Disable Auth.

## Suggested Monitors

Configure these monitors to track your lab's health:

| Name | Type | URL | Notes |
|------|------|-----|-------|
| Vault | HTTP | `http://<nomad01-ip>:8200/v1/sys/health?uninitcode=200&sealedcode=200` | Sealed/uninitialized counts as healthy |
| Authentik | HTTP | `http://<nomad01-ip>:9000/-/health/live/` | Live health endpoint |
| Traefik | HTTP | `http://<nomad01-ip>:8081/ping` | Ping endpoint |
| Nomad | HTTP | `http://<nomad01-ip>:4646/v1/status/leader` | Leader election |
| Pi-hole | HTTP | `http://<dns-01-ip>/admin/` | Admin page |
| Vault PKI | HTTP | `https://vault.<dns-suffix>/v1/sys/health` | Use -k for self-signed |

## DNS

The status page is accessible via:
```
https://status.<dns-suffix>
```

The DNS record `status.<dns-suffix>` is created automatically by Layer 2 Terraform when Uptime Kuma is deployed.

## Troubleshooting

### Not accessible via Traefik

```bash
# Check Traefik knows about the router
curl http://<nomad01-ip>:8081/api/http/routers | jq . | grep uptime

# Check Nomad service is registered
ssh labadmin@nomad01 "nomad service list | grep uptime"
```

### Container not starting

```bash
ssh labadmin@nomad01 "nomad alloc logs -job uptime-kuma"
```

### Lost admin access

Reset by clearing data (loses all monitor configuration):

```bash
ssh labadmin@nomad01 "sudo rm -rf /srv/gluster/nomad-data/uptime-kuma/*"
# Then stop and restart the job
ssh labadmin@nomad01 "nomad job stop uptime-kuma"
# Redeploy via setup.sh option 5
```
