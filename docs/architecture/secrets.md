# Secrets Architecture

## Overview

All secrets are stored in HashiCorp Vault. No passwords, tokens, or credentials are stored in Terraform state, environment variables, or configuration files on Nomad nodes. Services authenticate to Vault using Workload Identity Federation (WIF) — short-lived JWTs issued by Nomad — rather than long-lived tokens.

## Vault Layout

### KV v2 Secret Paths

All secrets are stored in the `secret/` KV v2 mount:

| Path | Contents | Used by |
|------|----------|---------|
| `secret/pihole` | `admin_password`, `root_password` | Pi-hole LXC provisioning |
| `secret/kasm` | `admin_password` | Kasm VM provisioning |
| `secret/packer` | `root_password`, `ssh_password`, `template_password` | Packer builds |
| `secret/ssh-keys` | `labadmin`, `labadmin_pub`, `enterprise`, `enterprise_pub` | SSH key reference |
| `secret/authentik` | `secret_key`, `postgres_password`, `admin_password`, `admin_email`, `api_token` | Authentik job |
| `secret/samba-ad` | `admin_password` | Samba AD provisioning |
| `secret/samba-ad/service-accounts` | `domain_join_password`, `domain_join_dn`, `authentik_sync_password`, `authentik_sync_dn`, `lam_bind_password`, `lam_bind_dn` | Service account passwords |
| `secret/netbox` | `secret_key`, `postgres_password`, `admin_password`, `admin_email`, `api_token` | Netbox job |
| `secret/unifi` | `address`, `api_key`, `site` | Netbox UniFi sync |
| `secret/nas/<name>` | `type`, `address`, `api_key`, `admin_user`, `admin_password` | NAS domain join |
| `secret/tailscale` | `auth_key` | Tailscale subnet router |
| `secret/config/cluster` | `dns_postfix`, `dns_server`, `network_cidr`, `gateway`, `ad_realm`, `base_dn` | Shared cluster config |
| `secret/config/nomad-nodes` | `nomad01_ip`, `nomad02_ip`, `nomad03_ip` | Node IP reference |

### Vault PKI

Two-tier certificate authority:

| Mount | Type | TTL | Purpose |
|-------|------|-----|---------|
| `pki/` | Root CA | 10 years | Root certificate authority |
| `pki_int/` | Intermediate CA | 5 years | Issues service certificates |

The root CA certificate can be downloaded from `https://vault.<dns-suffix>/v1/pki/ca/pem` and imported into client certificate stores.

Traefik's wildcard TLS certificate (`*.<dns-suffix>`) is issued from `pki_int/` at deploy time with a 1-year TTL. It is stored at:
- `/srv/gluster/nomad-data/traefik/tls/cert.pem`
- `/srv/gluster/nomad-data/traefik/tls/key.pem`

Re-issue by re-running option 4 (Deploy Traefik) from the developer menu.

### Vault Auth Methods

| Path | Type | Purpose |
|------|------|---------|
| `jwt-nomad` | JWT | Nomad Workload Identity Federation |

The JWT auth backend is configured with:
- JWKS URL: `http://<nomad01-ip>:4646/.well-known/jwks.json`
- Default role: `nomad-workloads`
- Per-service roles bound by `nomad_job_id` claim

## Workload Identity Federation (WIF)

WIF allows Nomad workloads to authenticate to Vault using short-lived JWTs without any long-lived tokens stored on nodes or in job definitions.

### How it works

```
Nomad job starts
    |
    v
Nomad signs a JWT for the workload
  Claims: nomad_job_id, nomad_namespace, nomad_task
  Audience: "vault.io"
    |
    v
Job task runs: vault login -method=jwt -path=jwt-nomad -role=<service>
    |
    v
Vault validates JWT signature using Nomad's JWKS endpoint
Vault checks bound_claims: nomad_job_id == "<service>"
    |
    v
Vault issues short-lived service token (1-hour TTL, auto-renews)
    |
    v
Service reads secrets from Vault using the token
```

### JWT Roles

Each service has its own JWT role with a policy that limits access to its own secrets:

| Role name | Bound job ID | Policy | Can read |
|-----------|-------------|--------|---------|
| `authentik` | `authentik` | `authentik` | `secret/data/authentik` |
| `samba-ad` | `samba-ad` | `samba-ad` | `secret/data/samba-ad`, `secret/data/config/*` |
| `backup` | `backup` | `backup` | `secret/data/backup` |
| `lam` | `lam` | `lam` | `secret/data/samba-ad/service-accounts`, `secret/data/config/*` |
| `netbox` | `netbox` | `netbox` | `secret/data/netbox`, `secret/data/unifi` |
| `tailscale` | `tailscale` | `tailscale` | `secret/data/tailscale` |

### Nomad Job Configuration

Jobs authenticate to Vault using the `vault` stanza and a Nomad `identity` block:

```hcl
vault {
  role = "authentik"
}

identity {
  env  = true
  file = true
}
```

Vault-injected secrets are accessed via Nomad templates:

```hcl
template {
  data = <<EOH
{{ with secret "secret/data/authentik" }}
AUTHENTIK_SECRET_KEY={{ .Data.data.secret_key }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
EOH
  destination = "secrets/authentik.env"
  env         = true
}
```

## Vault Credentials File

After Vault initialization, `crypto/vault-credentials.json` contains:

```json
{
  "unseal_key": "<unseal-key>",
  "root_token": "hvs.xxx",
  "vault_address": "https://<nomad01-ip>:8200",
  "initialized_at": "2026-01-01T00:00:00Z"
}
```

This file is used by:
- The setup script to unseal Vault after restarts
- Layer 2 Terraform initialization (root token written to `terraform/services/terraform.tfvars`)
- Layer 1 `vault.auto.tfvars` for the nomad provider

!!! danger "Protect vault-credentials.json"
    This file contains the Vault root token and unseal key. It is git-ignored. Loss of this file means you cannot unseal Vault after a restart, making all secrets inaccessible. Back it up securely.

## Secret Generation

All service passwords are randomly generated by Terraform using `random_password` resources with `keepers`:

```hcl
resource "random_password" "authentik_secret_key" {
  length  = 50
  special = false
  keepers = { service = "authentik" }
}
```

The `keepers` map ensures the password is only regenerated if the keeper value changes — not on every `terraform apply`. This prevents accidental password rotation.

## Vault TLS Bootstrap

Vault's TLS configuration goes through a two-phase bootstrap:

**Phase 1 — HTTP:** Vault starts with `tls_disable = true`. This allows Vault to initialize and Layer 2 to configure PKI without a chicken-and-egg problem.

**Phase 2 — HTTPS:** After Layer 2 has configured the PKI and issued a Vault listener certificate, the `vault` Nomad job is redeployed with `vault_tls_enabled = true`. Vault serves HTTPS using a certificate issued by its own PKI.

The `vault_address` in `crypto/vault-credentials.json` is updated from `http://` to `https://` after this transition.

When Vault serves HTTPS, the internal root CA certificate is distributed to all Nomad VMs' system trust stores so the Nomad agents trust Vault's certificate.

## Accessing Vault Manually

```bash
# Using the root token from credentials file
export VAULT_TOKEN=$(jq -r '.root_token' crypto/vault-credentials.json)
export VAULT_ADDR=$(jq -r '.vault_address' crypto/vault-credentials.json)
export VAULT_SKIP_VERIFY=true  # Required if your workstation doesn't trust the internal CA

# List secrets
docker compose run --rm vault vault kv list secret/

# Read a secret
docker compose run --rm vault vault kv get secret/authentik

# Read a specific field
docker compose run --rm vault vault kv get -field=admin_password secret/authentik
```

Or access the Vault UI at `https://vault.<dns-suffix>` and log in with the root token.

## Vault Unseal

Vault seals itself when the process restarts (e.g., after a Nomad job reschedule). The setup script's `initAndUnsealVault` function handles unsealing using the saved key.

To manually unseal:

```bash
VAULT_ADDR=$(jq -r '.vault_address' crypto/vault-credentials.json)
UNSEAL_KEY=$(jq -r '.unseal_key' crypto/vault-credentials.json)

curl -sk -X PUT "$VAULT_ADDR/v1/sys/unseal" \
  -H "Content-Type: application/json" \
  -d "{\"key\": \"$UNSEAL_KEY\"}"
```

Or from the Vault UI: navigate to `https://vault.<dns-suffix>/ui/vault/unseal`.

## Nomad-Vault Integration

The Nomad servers themselves are configured to trust Vault for workload identity. This configuration is applied by Layer 2 (`nomad-vault-integration.tf`) and pushed to each Nomad VM via SSH.

The key configuration in `/etc/nomad.d/nomad.hcl`:

```hcl
vault {
  enabled = true
  address = "https://<nomad01-ip>:8200"
  jwt_auth_backend_path = "jwt-nomad"
  create_from_role = "nomad-workloads"

  default_identity {
    aud  = ["vault.io"]
    ttl  = "1h"
  }
}
```
