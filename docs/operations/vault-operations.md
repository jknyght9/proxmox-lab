# Vault Operations

Daily operations guide for managing HashiCorp Vault secrets and policies.

## Accessing Vault

### Web UI

URL: `https://vault.mylab.lan` (via Traefik) or `http://nomad01:8200` (direct)

Login with root token from `crypto/vault-credentials.json`.

### CLI via Docker

```bash
# From project root
export VAULT_ADDR="http://nomad01:8200"
export VAULT_TOKEN="<root-token-from-file>"

# Run commands
docker compose run --rm vault status
docker compose run --rm vault kv list secret/
```

### CLI via SSH

```bash
ssh ubuntu@nomad01

export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="<root-token>"

vault status
```

## Unsealing Vault

Vault automatically seals on restart for security.

### Check Seal Status

```bash
vault status

# Or via curl
curl http://nomad01:8200/v1/sys/health | jq .
```

### Unseal via setup.sh

```bash
./setup.sh
# Select option 10: Unseal Vault
```

### Manual Unseal

```bash
# Get unseal key
UNSEAL_KEY=$(jq -r .unseal_key crypto/vault-credentials.json)

# Unseal
vault operator unseal "$UNSEAL_KEY"

# Or via curl
curl -X PUT http://nomad01:8200/v1/sys/unseal \
  -H "Content-Type: application/json" \
  -d "{\"key\": \"$UNSEAL_KEY\"}"
```

## Secrets Management

### Storing Secrets

```bash
# KV v2 format (note: secret/data/ path)
vault kv put secret/my-service \
  username="admin" \
  password="secret123" \
  api_key="abc123"

# From file
vault kv put secret/my-service @secrets.json

# From stdin
cat secrets.json | vault kv put secret/my-service -
```

### Reading Secrets

```bash
# Read secret
vault kv get secret/authentik

# JSON output
vault kv get -format=json secret/authentik

# Specific field
vault kv get -field=postgres_password secret/authentik
```

### Updating Secrets

```bash
# Update single field (preserves others)
vault kv patch secret/authentik new_field="value"

# Replace all fields
vault kv put secret/authentik \
  postgres_password="newpass" \
  secret_key="newsecret"
```

### Deleting Secrets

```bash
# Delete latest version
vault kv delete secret/my-service

# Delete specific version
vault kv delete -versions=2 secret/my-service

# Permanently destroy
vault kv destroy -versions=1,2 secret/my-service

# Undelete
vault kv undelete -versions=1 secret/my-service
```

### Listing Secrets

```bash
# List all secret paths
vault kv list secret/

# Tree view
vault kv list -format=json secret/ | jq -r '.[]'
```

## Policy Management

### Listing Policies

```bash
vault policy list
```

### Reading Policies

```bash
vault policy read authentik
```

### Creating Policies

```bash
# From file
vault policy write my-service policy.hcl

# Inline
vault policy write my-service - <<EOF
path "secret/data/my-service/*" {
  capabilities = ["read"]
}
EOF
```

Policy file example:

```hcl
# Allow reading service secrets
path "secret/data/my-service/*" {
  capabilities = ["read", "list"]
}

# Allow reading metadata
path "secret/metadata/my-service/*" {
  capabilities = ["read", "list"]
}
```

### Updating Policies

```bash
# Overwrite existing policy
vault policy write my-service updated-policy.hcl
```

### Deleting Policies

```bash
vault policy delete my-service
```

## JWT Auth Management

### Listing Roles

```bash
vault list auth/jwt-nomad/role
```

### Reading Roles

```bash
vault read auth/jwt-nomad/role/authentik
```

### Creating Roles

```bash
vault write auth/jwt-nomad/role/my-service \
  role_type="jwt" \
  bound_audiences="vault.io" \
  user_claim="/nomad_job_id" \
  user_claim_json_pointer=true \
  bound_claims='{"nomad_job_id":"my-service"}' \
  token_policies="my-service" \
  token_ttl="1h"
```

### Updating Roles

```bash
# Update specific field
vault write auth/jwt-nomad/role/my-service \
  token_policies="my-service,additional-policy"
```

### Deleting Roles

```bash
vault delete auth/jwt-nomad/role/my-service
```

## Token Management

### Creating Tokens

```bash
# Create token with policy
vault token create -policy=my-service

# Create token with TTL
vault token create -policy=my-service -ttl=1h

# Create orphan token (not revoked with parent)
vault token create -orphan -policy=my-service
```

### Revoking Tokens

```bash
# Revoke specific token
vault token revoke <token>

# Revoke all tokens for accessor
vault token revoke -accessor <accessor>

# Revoke all tokens with policy
vault token revoke -policy my-service
```

### Looking Up Tokens

```bash
# Self lookup
vault token lookup

# Lookup specific token
vault token lookup <token>

# Renew token
vault token renew <token>
```

## Audit Logging

### Enable Audit Device

```bash
# File audit device
vault audit enable file file_path=/tmp/vault-audit.log

# Syslog audit device
vault audit enable syslog tag="vault" facility="AUTH"
```

### List Audit Devices

```bash
vault audit list
```

### Disable Audit Device

```bash
vault audit disable file/
```

## Backup and Recovery

### Backup Secrets

```bash
# Export all secrets (requires root or appropriate permissions)
for path in $(vault kv list -format=json secret/ | jq -r '.[]'); do
  vault kv get -format=json "secret/$path" > "backup-${path}.json"
done
```

### Backup Policies

```bash
for policy in $(vault policy list); do
  vault policy read "$policy" > "policy-${policy}.hcl"
done
```

### Backup Configuration

```bash
# Raft snapshot (if using integrated storage)
vault operator raft snapshot save backup.snap

# For file backend, backup the directory
ssh ubuntu@nomad01
sudo tar -czf vault-data-backup.tar.gz /srv/gluster/nomad-data/vault/
```

### Restore

```bash
# Restore secrets (redeploy from backup files)
vault kv put secret/authentik @backup-authentik.json

# Restore policies
vault policy write authentik policy-authentik.hcl

# Restore Raft snapshot (if applicable)
vault operator raft snapshot restore backup.snap

# For file backend
ssh ubuntu@nomad01
sudo tar -xzf vault-data-backup.tar.gz -C /srv/gluster/nomad-data/
```

## Monitoring

### Health Check

```bash
# Check health
curl http://nomad01:8200/v1/sys/health | jq .

# Healthy unsealed response:
{
  "initialized": true,
  "sealed": false,
  "standby": false,
  ...
}
```

### Metrics

```bash
# Prometheus metrics
curl http://nomad01:8200/v1/sys/metrics?format=prometheus
```

### Logs

```bash
# Vault container logs
nomad alloc logs -f -job vault
```

## Troubleshooting

### Vault is Sealed

This is normal after restart. Simply unseal:

```bash
./setup.sh  # option 10
```

### Cannot Authenticate

```bash
# Verify JWT auth is enabled
vault auth list

# Check JWKS is accessible
curl http://nomad01:4646/.well-known/jwks.json

# Verify role configuration
vault read auth/jwt-nomad/role/authentik
```

### Secrets Not Found

```bash
# List secrets
vault kv list secret/

# Check path (remember KV v2 uses secret/data/)
vault kv get secret/authentik  # correct
vault kv get secret/data/authentik  # incorrect (CLI handles this)
```

### Permission Denied

```bash
# Check token capabilities
vault token capabilities <token> secret/data/authentik

# Expected: ["read"]
```

### Storage Issues

```bash
# Check GlusterFS mount
ssh ubuntu@nomad01
df -h | grep nomad-data

# Check permissions
ls -la /srv/gluster/nomad-data/vault/

# Should be writable by Vault container
```

## Security Best Practices

### Root Token

- Store securely in `crypto/vault-credentials.json`
- Never commit to git (already in `.gitignore`)
- Use separate tokens for applications
- Revoke when not needed

### Policies

- Principle of least privilege
- Separate policies per service
- Use path wildcards sparingly
- Regular audit reviews

### Tokens

- Use short TTLs (1 hour default)
- Use WIF instead of long-lived tokens
- Revoke unused tokens
- Rotate regularly

### Secrets

- Never store in job files
- Inject via template stanza
- Rotate periodically
- Use Vault versioning

## Integration Examples

### Adding New Service Secrets

1. Create secrets in Vault:

```bash
vault kv put secret/my-service \
  db_password="secret" \
  api_key="key123"
```

2. Create policy:

```bash
vault policy write my-service - <<EOF
path "secret/data/my-service" {
  capabilities = ["read"]
}
EOF
```

3. Create role:

```bash
vault write auth/jwt-nomad/role/my-service \
  role_type="jwt" \
  bound_audiences="vault.io" \
  user_claim="/nomad_job_id" \
  bound_claims='{"nomad_job_id":"my-service"}' \
  token_policies="my-service" \
  token_ttl="1h"
```

4. Use in Nomad job:

```hcl
job "my-service" {
  vault {
    role = "my-service"
  }

  task "app" {
    template {
      data = <<EOH
{{ with secret "secret/data/my-service" }}
DB_PASSWORD={{ .Data.data.db_password }}
API_KEY={{ .Data.data.api_key }}
{{ end }}
EOH
      destination = "secrets/app.env"
      env         = true
    }
  }
}
```

## Next Steps

- [:octicons-arrow-right-24: Vault Module](../modules/vault.md)
- [:octicons-arrow-right-24: Nomad Operations](nomad-operations.md)
- [:octicons-arrow-right-24: Authentik Module](../modules/authentik.md)
- [Vault Documentation](https://developer.hashicorp.com/vault/docs)
