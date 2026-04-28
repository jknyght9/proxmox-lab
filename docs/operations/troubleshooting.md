# Troubleshooting

Common issues and their solutions.

## Vault Issues

### Vault sealed after restart

Vault seals itself when the process restarts. The setup script unseals automatically during deployment, but manual intervention is needed after unplanned restarts.

```bash
VAULT_ADDR=$(jq -r '.vault_address' crypto/vault-credentials.json)
UNSEAL_KEY=$(jq -r '.unseal_key' crypto/vault-credentials.json)

curl -sk -X PUT "$VAULT_ADDR/v1/sys/unseal" \
  -H "Content-Type: application/json" \
  -d "{\"key\": \"$UNSEAL_KEY\"}"
```

### Vault initialized but credentials file missing

This means a previous deployment crashed after Vault initialized but before credentials were saved. The script auto-recovers:

1. Detects initialized-but-no-credentials state
2. Stops and wipes Vault data
3. Redeploys Vault job
4. Re-initializes fresh

This is triggered automatically when you re-run option 1.

### Permission denied on Vault storage

Vault cannot write to GlusterFS. Ensure the container is privileged:

```bash
ssh labadmin@nomad01 "docker inspect \$(docker ps -q --filter name=vault) | jq '.[0].HostConfig.Privileged'"
```

Should return `true`. If not, the Nomad job definition is incorrect — check that `privileged = true` is in the task config.

### Vault not accessible after TLS redeploy

After Vault redeploys with TLS, it seals itself and needs unseal. Also, the Nomad nodes may not yet trust the internal CA:

```bash
# Unseal
VAULT_ADDR="https://<nomad01-ip>:8200"
UNSEAL_KEY=$(jq -r '.unseal_key' crypto/vault-credentials.json)
curl -sk -X PUT "$VAULT_ADDR/v1/sys/unseal" \
  -H "Content-Type: application/json" \
  -d "{\"key\": \"$UNSEAL_KEY\"}"

# Check CA trust on Nomad nodes
ssh labadmin@nomad01 "openssl s_client -connect <nomad01-ip>:8200 </dev/null 2>&1 | grep -E 'Verify|OK'"
```

## Traefik Issues

### 404 errors for a service

1. Verify the service is running: `nomad job status <service>`
2. Check service is registered: `nomad service list`
3. Check Traefik knows about the router:
   ```bash
   curl http://<nomad01-ip>:8081/api/http/routers | jq '.[].rule' | grep <service>
   ```
4. Verify `traefik.enable=true` is in the Nomad service tags

### TLS certificate expired or missing

Re-issue the wildcard certificate by redeploying Traefik:

```bash
./setup.sh --dev
# d9) Deploy Traefik only
```

Verify:
```bash
echo | openssl s_client -connect <dns-suffix>:443 2>/dev/null | openssl x509 -noout -dates
```

### Service discovered but returns 502

The Traefik backend cannot reach the upstream service. Check:

1. Is the upstream service running? Check Nomad allocation logs
2. Is the service listening on the correct port?
3. For HTTPS backends (like Vault): ensure `--serversTransport.insecureSkipVerify=true` is in Traefik args

## DNS Issues

### FQDN not resolving but IP works

Your client is not using Pi-hole for DNS. Configure your device to use the Pi-hole IP (or HA VIP):

```bash
# Verify which DNS you're using
nslookup vault.<dns-suffix>
# Should show "Server: <pihole-ip>"
```

### DNS resolves to wrong IP

DNS records may be outdated. Rebuild them:

```bash
./setup.sh --dev
# d11) Rebuild DNS records
```

### Container provisioning fails during apt-get

Your network blocks external DNS. Set `bootstrap_dns` to your gateway:

```hcl
# terraform/terraform.tfvars
bootstrap_dns = "<gateway-ip>"
```

Then re-run the deployment.

### Pi-hole not syncing between nodes

Test Gravity Sync connectivity:

```bash
ssh labadmin@dns-01 "ssh -i /etc/gravity-sync/gravity-sync.rsa dns-02 echo ok"
```

Run sync manually:

```bash
ssh labadmin@dns-01 "sudo gravity sync push"
ssh labadmin@dns-02 "sudo gravity sync logs"
```

## Nomad Issues

### GlusterFS not mounted

The GlusterFS sentinel file check is failing. Run the mount fix:

```bash
ssh labadmin@nomad01 "mountpoint -q /srv/gluster/nomad-data && echo mounted || echo NOT MOUNTED"

# If not mounted, restart glusterd
ssh labadmin@nomad01 "sudo systemctl restart glusterd"
ssh labadmin@nomad01 "sudo mount -a"
```

Check the sentinel:
```bash
ssh labadmin@nomad01 "ls -la /srv/gluster/nomad-data/.mount-sentinel"
```

If the sentinel is missing, create it:
```bash
ssh labadmin@nomad01 "sudo touch /srv/gluster/nomad-data/.mount-sentinel"
```

### Nomad job stuck in pending

The job cannot be scheduled. Common causes:

```bash
# Check job status and why it's not scheduled
ssh labadmin@nomad01 "nomad job status <job>"
ssh labadmin@nomad01 "nomad alloc status <alloc-id>"
```

Common issues:
- GlusterFS not mounted (prestart task failing)
- Constraint not matching (e.g., `hostname == nomad01` but node is `nomad01.mylab.lan`)
- Resource constraints (not enough CPU/memory)

### Nomad cluster not forming quorum

Check that all three Nomad nodes can see each other:

```bash
ssh labadmin@nomad01 "nomad server members"
```

Should show all three nodes as `alive`. If a node shows as `failed`, check:
1. Is the Nomad service running? `systemctl status nomad`
2. Can nodes reach each other? `ping nomad02`
3. Are retry_join IPs correct in `/etc/nomad.d/nomad.hcl`?

## Authentik Issues

### Authentik not starting

Check allocation logs:

```bash
ssh labadmin@nomad01 "nomad alloc logs -job authentik -task authentik-server"
```

Common causes:
- Vault WIF authentication failing (check Vault is unsealed and accessible)
- PostgreSQL not ready yet (Authentik starts before DB is fully initialized — wait 30-60s)
- GlusterFS directories missing

### Admin password doesn't match Vault

The admin password is set during first database initialization. If Vault was reinitialized with different secrets:

```bash
# Get current password from Vault
ADMIN_PW=$(vault kv get -field=admin_password secret/authentik)
API_TOKEN=$(vault kv get -field=api_token secret/authentik)

# Get admin user PK
ADMIN_PK=$(curl -sk -H "Authorization: Bearer $API_TOKEN" \
  "https://<nomad01-ip>:9443/api/v3/core/users/?username=akadmin" | jq -r '.results[0].pk')

# Reset password
curl -sk -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -X POST "https://<nomad01-ip>:9443/api/v3/core/users/$ADMIN_PK/set_password/" \
  -d "{\"password\":$(echo "$ADMIN_PW" | jq -Rs .)}"
```

### goauthentik Terraform provider errors

The `goauthentik/authentik` Terraform provider has known bugs with `invalidation_flow` on OAuth2 and LDAP providers. All Authentik configuration is done via REST API (`null_resource + curl`) for this reason. If you see provider errors, check if the API-based provisioning succeeded:

```bash
ssh labadmin@nomad01 "curl -sk -H 'Authorization: Bearer <api-token>' \
  https://<nomad01-ip>:9443/api/v3/core/applications/ | jq '[.results[].name]'"
```

## Samba AD Issues

### Domain controller not starting

```bash
# Check container status
ssh labadmin@nomad01 "docker ps | grep samba"
ssh labadmin@nomad01 "nomad alloc logs -job samba-ad"
```

Common causes:
- GlusterFS not mounted for the samba data directories
- Port 88/389/445 already in use (check for previous stale allocations)
- DNS not resolving AD realm (verify Pi-hole has AD DNS forwarding)

### Replication between DC01 and DC02 failing

```bash
# Check replication status inside DC01
CONTAINER=$(docker ps --format '{{.ID}} {{.Names}}' | grep samba-ad | head -1 | awk '{print $1}')
docker exec $CONTAINER samba-tool drs showrepl
```

Check DNS connectivity between nodes:
```bash
dig @<dns-01-ip> _ldap._tcp.<ad-realm-lowercase> SRV
```

### Domain join fails for a NAS

1. Verify DNS: `dig @<dns-01-ip> <ad-realm-lowercase>` should resolve
2. Verify `domain-join-svc` account exists in AD:
   ```bash
   docker exec $CONTAINER samba-tool user show domain-join-svc
   ```
3. Check the join credentials are correct in Vault:
   ```bash
   vault kv get secret/samba-ad/service-accounts
   ```

## HA and keepalived Issues

### VIP not bound on any node

```bash
# Check keepalived logs
ssh labadmin@dns-01 "journalctl -u keepalived -n 30"
```

Common issues:
- VRRP router ID conflict with another device on the network
- Firewall blocking VRRP multicast (protocol 112)
- VRRP password mismatch (check it is identical on all nodes, max 8 chars)

### DNS still failing even with HA VIP

Check the VIP is bound and responding:

```bash
# Is VIP bound on any node?
ssh labadmin@dns-01 "ip addr show eth0 | grep <vip-ip>"
ssh labadmin@dns-02 "ip addr show eth0 | grep <vip-ip>"

# Does Pi-hole respond on the VIP?
dig @<vip-ip> google.com
```

## Packer Build Issues

### Build fails downloading cloud image

The base Ubuntu cloud image download may fail due to network issues:

```bash
# Check what's happening in Packer
docker compose run packer build -debug -only='base-ubuntu.*' .
```

If your network requires a proxy, set the appropriate environment variables before running Packer.

### Template already exists error

Packer may fail if a partial template from a previous failed build exists:

```bash
# Remove the partial template
ssh root@<proxmox-ip> "qm status 9999 && qm destroy 9999 || true"
```

Then retry the build.
