# Traefik

Traefik is the reverse proxy and load balancer for all Nomad-managed services. It automatically discovers services via the Nomad provider and uses a wildcard TLS certificate issued from Vault PKI.

## Overview

| Property | Value |
|----------|-------|
| **Nomad Job** | `traefik` |
| **Image** | `traefik:v3.6` |
| **Type** | `system` (runs on all Nomad nodes) |
| **Ports** | 80 (HTTP), 443 (HTTPS), 8081 (Dashboard) |
| **Network Mode** | Host |
| **Storage** | GlusterFS host volume mounted at `/data` |
| **TLS** | Wildcard cert (`*.<dns-suffix>`) from Vault PKI |
| **Cert location** | `/srv/gluster/nomad-data/traefik/tls/cert.pem` and `key.pem` |

## Deployment

Traefik is deployed by Layer 2 Terraform (`terraform/services/nomad-jobs.tf`). It is always the first service deployed and is a prerequisite for all other services that need HTTPS access through the reverse proxy.

To redeploy Traefik (and re-issue the wildcard TLS certificate):

```bash
./setup.sh --dev
# Select: d9) Deploy Traefik only
```

Or use Layer 2 Terraform directly:

```bash
docker compose run terraform-services apply -auto-approve -target=nomad_job.traefik
```

## TLS Configuration

Traefik does not use ACME or cert-manager. Instead, a wildcard certificate is issued directly from the Vault intermediate CA (`pki_int/`) at deploy time:

- **Certificate**: `*.<dns-suffix>`
- **SANs**: `*.<dns-suffix>`, `<dns-suffix>`
- **TTL**: 1 year
- **Issuer**: Vault `pki_int/` intermediate CA
- **Storage**: `/srv/gluster/nomad-data/traefik/tls/` (on GlusterFS)

!!! note "No certResolver tags"
    Nomad service tags use `tls=true` only. There is no `certresolver` tag. Traefik serves the wildcard certificate as the default TLS certificate for all HTTPS connections via a file provider configuration at `/data/traefik/config/tls.yml`.

!!! info "Vault 1.21.x ACME nonce bug"
    Vault 1.21.x has a bug in its ACME endpoint that causes nonce errors. Wildcard cert issuance via Vault's PKI secrets engine (`/v1/pki_int/issue/`) works correctly and is used instead.

To re-issue the certificate (e.g., after expiry or DNS suffix change), redeploy Traefik via option `d9`. The Layer 2 `null_resource.install_traefik_cert` always issues a fresh certificate on apply.

## Service Discovery

Traefik discovers services via the Nomad provider:

```
--providers.nomad=true
--providers.nomad.endpoint.address=http://127.0.0.1:4646
--providers.nomad.exposedByDefault=false
--providers.nomad.namespaces=default
```

Services opt into Traefik routing by setting `traefik.enable=true` in their Nomad service tags. Services without this tag are not exposed through Traefik.

## Routing Rules

Each service defines its routing via Nomad service tags. Services accept both FQDN and short hostname:

```hcl
"traefik.http.routers.vault.rule=Host(`vault.<dns-suffix>`) || Host(`vault`)"
```

Entrypoints:

| Entrypoint | Port | Purpose |
|------------|------|---------|
| `web` | 80 | HTTP (no redirect to HTTPS by default) |
| `websecure` | 443 | HTTPS with wildcard TLS |
| `traefik` | 8081 | Dashboard (insecure, admin access only) |

## Authentik Forward Auth

Traefik is configured to use Authentik as a forward auth provider for protecting admin services. This is configured via a static middleware file at `/data/traefik/config/authentik.yml` (on GlusterFS), rendered from `nomad/config/traefik/authentik.yml`.

Services that require authentication add the middleware tag:

```hcl
"traefik.http.routers.pihole.middlewares=authentik@file"
```

Services accessible to all authenticated users (like Kasm) use a different outpost URL.

## Dashboard

The Traefik dashboard is available at:
```
http://<nomad01-ip>:8081
```

Or via DNS (through Traefik itself):
```
https://traefik.<dns-suffix>
```

The dashboard shows all configured routers, services, middlewares, and entrypoints.

## HA Configuration

When `ha_traefik_enabled: true` is set in `bootstrap.yml`, Traefik runs as a system job on all Nomad nodes and keepalived VRRP manages a VIP that floats to the highest-priority healthy node.

See [High Availability Configuration](../tutorials/ha-configuration.md) for setup instructions.

## Troubleshooting

### 404 errors for a service

Check that the service is registered in Nomad and has the correct tags:

```bash
# List registered services
nomad service list

# Check Traefik's view of routers
curl http://<nomad01-ip>:8081/api/http/routers | jq .

# Check services
curl http://<nomad01-ip>:8081/api/http/services | jq .
```

### TLS certificate missing or expired

Redeploy Traefik to re-issue the wildcard certificate:

```bash
./setup.sh --dev
# d9) Deploy Traefik only
```

Verify the certificate:

```bash
echo | openssl s_client -connect vault.<dns-suffix>:443 2>/dev/null | \
  openssl x509 -noout -dates
```

### Service not discovered by Traefik

1. Verify `traefik.enable=true` is in the service tags
2. Check the service is running: `nomad job status <service>`
3. Check Traefik logs: `nomad alloc logs -job traefik`
4. Verify the Nomad service is registered: `nomad service list`

## Deployment

Deploy Traefik using the setup menu:

```bash
./setup.sh
# Select option 7: Deploy Traefik
```

Or deploy directly with the Nomad CLI:

```bash
docker compose run --rm nomad job run /nomad/jobs/traefik.nomad.hcl
```

### Prerequisites

Before deploying Traefik, the following must be in place:

1. **Nomad cluster** -- All three Nomad nodes operational
2. **Pi-hole DNS** -- DNS records for services must resolve to nomad01
3. **Step-CA** -- Certificate Authority running and reachable at `ca.<dns_postfix>`
4. **GlusterFS** -- Shared volume mounted at `/srv/gluster/nomad-data` on all Nomad nodes

## Architecture

```mermaid
graph LR
    CLIENT[Client] -->|:80| HTTP[Entrypoint<br/>web]
    CLIENT -->|:443| HTTPS[Entrypoint<br/>websecure]

    HTTP --> ROUTER_HTTP[HTTP Routers]
    HTTPS --> ROUTER_HTTPS[HTTPS Routers]

    ROUTER_HTTP --> SERVICES[Nomad Services]
    ROUTER_HTTPS --> SERVICES

    HTTPS -->|ACME| STEPCA[step-ca]

    subgraph nomad["Nomad Service Discovery"]
        VAULT_SVC[vault :8200]
        AUTH_SVC[authentik :9000]
    end

    SERVICES --> nomad
```

Traefik runs in host networking mode on nomad01, binding directly to ports 80, 443, and 8081. All service DNS records (e.g., `vault.<domain>`, `auth.<domain>`) point to nomad01's IP address, so Traefik receives all inbound HTTP/HTTPS traffic and routes it to the appropriate backend.

## Entrypoints

Traefik defines three entrypoints:

| Entrypoint | Port | Purpose |
|------------|------|---------|
| `web` | 80 | HTTP traffic and ACME HTTP-01 challenges |
| `websecure` | 443 | HTTPS traffic with TLS termination |
| `traefik` | 8081 | Dashboard and API (insecure mode) |

## Service Discovery

Traefik uses the **Nomad provider** to automatically discover services registered in the Nomad cluster:

```
--providers.nomad=true
--providers.nomad.endpoint.address=http://127.0.0.1:4646
--providers.nomad.exposedByDefault=false
--providers.nomad.namespaces=default
--providers.nomad.allowEmptyServices=true
```

Key behaviors:

- **`exposedByDefault=false`** -- Services must explicitly opt in with `traefik.enable=true` in their Nomad service tags.
- **`allowEmptyServices=true`** -- Prevents Traefik from removing routes when a service temporarily has zero healthy instances.
- Traefik connects to the local Nomad agent at `http://127.0.0.1:4646` since it runs on nomad01 in host networking mode.

### Enabling a Service for Traefik

Nomad services opt in to Traefik routing by setting tags on their `service` stanza. For example, Vault registers itself as:

```hcl
service {
  name     = "vault"
  port     = "api"
  provider = "nomad"

  tags = [
    "traefik.enable=true",
    "traefik.http.routers.vault-http.rule=Host(`vault.mylab.lan`) || Host(`vault`)",
    "traefik.http.routers.vault-http.entrypoints=web",
    "traefik.http.routers.vault.rule=Host(`vault.mylab.lan`) || Host(`vault`)",
    "traefik.http.routers.vault.entrypoints=websecure",
    "traefik.http.routers.vault.tls=true",
    "traefik.http.routers.vault.tls.certresolver=step-ca",
    "traefik.http.services.vault.loadbalancer.server.port=8200",
  ]
}
```

Each service defines two routers:

- An **HTTP router** (entrypoint `web`) for plain HTTP access and ACME challenges.
- An **HTTPS router** (entrypoint `websecure`) with TLS enabled via the `step-ca` certificate resolver.

### Router Rules

All routers accept both the FQDN and the short hostname:

```
Host(`service.<dns_postfix>`) || Host(`service`)
```

This means `https://vault.mylab.lan` and `https://vault` both reach the same backend.

## ACME Certificate Management

Traefik automatically obtains TLS certificates from the internal step-ca using ACME:

```
--certificatesresolvers.step-ca.acme.email=admin@<dns_postfix>
--certificatesresolvers.step-ca.acme.storage=/data/traefik/acme.json
--certificatesresolvers.step-ca.acme.caserver=https://ca.<dns_postfix>/acme/acme/directory
--certificatesresolvers.step-ca.acme.httpchallenge=true
--certificatesresolvers.step-ca.acme.httpchallenge.entrypoint=web
```

### How It Works

```mermaid
sequenceDiagram
    participant Client
    participant Traefik
    participant StepCA as step-ca

    Client->>Traefik: HTTPS request for vault.mylab.lan
    Note over Traefik: No cert cached for this domain

    Traefik->>StepCA: ACME new-order (vault.mylab.lan)
    StepCA-->>Traefik: HTTP-01 challenge token

    Note over Traefik: Serves token on :80/.well-known/acme-challenge/

    StepCA->>Traefik: GET /.well-known/acme-challenge/[token]
    Traefik-->>StepCA: Challenge response

    StepCA->>StepCA: Validate challenge
    StepCA-->>Traefik: Signed certificate

    Traefik->>Traefik: Store cert in /data/traefik/acme.json
    Traefik-->>Client: TLS response with valid certificate
```

### CA Trust

Since step-ca uses a private root CA, Traefik must trust it to complete ACME requests. Two environment variables configure this:

| Variable | Value | Purpose |
|----------|-------|---------|
| `SSL_CERT_FILE` | `/data/certs/root_ca.crt` | System-level CA trust for Go's TLS |
| `LEGO_CA_CERTIFICATES` | `/data/certs/root_ca.crt` | LEGO ACME library CA trust |

The root CA certificate is stored on the GlusterFS volume at `/srv/gluster/nomad-data/certs/root_ca.crt`, which is mounted into the container at `/data/certs/root_ca.crt`.

### Certificate Storage

ACME certificates are persisted at `/data/traefik/acme.json` on the GlusterFS volume. This file is preserved across container restarts so certificates do not need to be re-issued.

## Health Check

Traefik registers itself as a Nomad service with an HTTP health check:

```hcl
service {
  name     = "traefik"
  port     = "dashboard"
  provider = "nomad"

  check {
    type     = "http"
    path     = "/ping"
    port     = "dashboard"
    interval = "10s"
    timeout  = "2s"
  }
}
```

The `/ping` endpoint is enabled via `--ping=true` and bound to the `traefik` entrypoint on port 8081.

## Dashboard

The Traefik dashboard provides a web interface to inspect routers, services, and middleware. It is enabled in insecure mode (no authentication) for lab use:

```
--api=true
--api.dashboard=true
--api.insecure=true
```

Access the dashboard at:

```
http://nomad01:8081/dashboard/
```

!!! warning "Trailing Slash Required"
    The dashboard URL must include the trailing slash: `/dashboard/`. Without it, Traefik returns a 404.

### Useful API Endpoints

| Endpoint | Purpose |
|----------|---------|
| `http://nomad01:8081/api/http/routers` | List all HTTP routers |
| `http://nomad01:8081/api/http/services` | List all HTTP services |
| `http://nomad01:8081/api/entrypoints` | List entrypoints |
| `http://nomad01:8081/ping` | Health check |

Query routers to verify service discovery:

```bash
curl -s http://nomad01:8081/api/http/routers | jq .
```

## Verifying the Deployment

After deploying Traefik, verify it is running correctly:

```bash
# Check job status
docker compose run --rm nomad job status traefik

# Check allocation logs
docker compose run --rm nomad alloc logs -job traefik

# Verify the service is registered
docker compose run --rm nomad service list

# Test the ping endpoint
curl http://nomad01:8081/ping

# Check discovered routers
curl -s http://nomad01:8081/api/http/routers | jq '.[].rule'
```

## Troubleshooting

??? question "404 Not Found for a service"
    Traefik is running but cannot route the request to a backend.

    1. Check that the service is registered in Nomad:
        ```bash
        docker compose run --rm nomad service list
        ```
    2. Verify the router exists in Traefik:
        ```bash
        curl -s http://nomad01:8081/api/http/routers | jq .
        ```
    3. Confirm DNS resolves the service hostname to nomad01's IP:
        ```bash
        nslookup vault.mylab.lan
        ```
    4. Check that the service's Nomad tags include `traefik.enable=true`.

??? question "ACME certificate challenges failing"
    Traefik cannot obtain a TLS certificate from step-ca.

    1. Verify step-ca is running and reachable:
        ```bash
        curl -k https://ca.mylab.lan/health
        ```
    2. Check that DNS resolves the service domain to nomad01 (step-ca must be able to reach Traefik on port 80 for HTTP-01 challenges).
    3. Inspect the ACME storage file for errors:
        ```bash
        ssh nomad01 'cat /srv/gluster/nomad-data/traefik/acme.json | jq .'
        ```
    4. Clear stale ACME data and restart the job:
        ```bash
        ssh nomad01 'rm /srv/gluster/nomad-data/traefik/acme.json'
        docker compose run --rm nomad job stop -purge traefik
        docker compose run --rm nomad job run /nomad/jobs/traefik.nomad.hcl
        ```

??? question "Service not discovered by Traefik"
    The service is running in Nomad but does not appear in Traefik's router list.

    1. Verify the service is healthy in Nomad:
        ```bash
        docker compose run --rm nomad job status <job-name>
        ```
    2. Check that the service uses `provider = "nomad"` (not Consul).
    3. Confirm the service tags include `traefik.enable=true`.
    4. Inspect Traefik logs for discovery errors:
        ```bash
        docker compose run --rm nomad alloc logs -job traefik
        ```

??? question "Port 80 or 443 already in use"
    Another process is binding to Traefik's ports on nomad01.

    1. Identify what is using the port:
        ```bash
        ssh nomad01 'sudo ss -tlnp | grep -E ":80|:443"'
        ```
    2. Stop/purge any stale Traefik allocations:
        ```bash
        docker compose run --rm nomad job stop -purge traefik
        ```

## Next Steps

- [:octicons-arrow-right-24: Vault](vault.md) -- Secrets management (routed through Traefik)
- [:octicons-arrow-right-24: Authentik](authentik.md) -- Identity provider (routed through Traefik)
- [:octicons-arrow-right-24: Certificate Chain](../architecture/certificate-chain.md) -- How TLS certificates are issued
