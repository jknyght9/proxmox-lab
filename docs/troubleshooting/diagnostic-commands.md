# Diagnostic Commands

This page provides a comprehensive reference of commands for checking the health and status of every component in Proxmox Lab. Use these commands when investigating issues or verifying that everything is working correctly.

---

## Nomad Cluster

### Cluster Status

```bash
# Server members and leader election
docker compose run --rm nomad server members

# Node (client) status
docker compose run --rm nomad node status

# Raft consensus peers
docker compose run --rm nomad operator raft list-peers
```

### Job Status

```bash
# List all jobs
docker compose run --rm nomad job status

# Detailed job status
docker compose run --rm nomad job status <job-name>

# View allocation logs
docker compose run --rm nomad alloc logs -job <job-name>

# View allocation stderr
docker compose run --rm nomad alloc logs -job <job-name> -stderr

# Follow logs in real time
docker compose run --rm nomad alloc logs -job <job-name> -f

# Detailed allocation status (includes events and restarts)
docker compose run --rm nomad alloc status <alloc-id>
```

### Service Discovery

```bash
# List all registered services
docker compose run --rm nomad service list

# View a specific service
docker compose run --rm nomad service info <service-name>
```

---

## Vault

### Health and Seal Status

```bash
# Full health check (returns JSON with initialized, sealed, version, etc.)
curl -s http://<nomad01-ip>:8200/v1/sys/health | jq .

# Quick seal status check
curl -s http://<nomad01-ip>:8200/v1/sys/seal-status | jq .
```

**Interpreting health responses:**

| HTTP Code | Meaning |
|-----------|---------|
| 200 | Initialized, unsealed, active |
| 429 | Unsealed but in standby |
| 472 | Disaster recovery secondary |
| 501 | Not initialized |
| 503 | Sealed |

### Vault Secrets

```bash
# List secret engines (requires root token)
curl -s -H "X-Vault-Token: <root-token>" http://<nomad01-ip>:8200/v1/sys/mounts | jq .

# Read a secret
curl -s -H "X-Vault-Token: <root-token>" http://<nomad01-ip>:8200/v1/secret/data/authentik | jq .

# Check auth methods
curl -s -H "X-Vault-Token: <root-token>" http://<nomad01-ip>:8200/v1/sys/auth | jq .
```

### Vault WIF Configuration

```bash
# Check JWT auth backend at jwt-nomad
curl -s -H "X-Vault-Token: <root-token>" http://<nomad01-ip>:8200/v1/auth/jwt-nomad/config | jq .

# List roles in the JWT auth backend
curl -s -H "X-Vault-Token: <root-token>" http://<nomad01-ip>:8200/v1/auth/jwt-nomad/role?list=true | jq .
```

---

## Traefik

### Dashboard and API

```bash
# Check Traefik is responding
curl -s http://<nomad01-ip>:8081/api/overview | jq .

# List all HTTP routers (shows routing rules)
curl -s http://<nomad01-ip>:8081/api/http/routers | jq .

# List all HTTP services (shows backends)
curl -s http://<nomad01-ip>:8081/api/http/services | jq .

# List all entrypoints
curl -s http://<nomad01-ip>:8081/api/entrypoints | jq .

# Check a specific router
curl -s http://<nomad01-ip>:8081/api/http/routers/<router-name> | jq .
```

### Traefik Logs

```bash
# View Traefik logs via Nomad
docker compose run --rm nomad alloc logs -job traefik
docker compose run --rm nomad alloc logs -job traefik -stderr
```

---

## Pi-hole DNS

### Service Status

```bash
# Check pihole-FTL service status
ssh root@<dns-ip> "systemctl status pihole-FTL"

# View pihole-FTL logs
ssh root@<dns-ip> "journalctl -u pihole-FTL --no-pager -n 50"
```

### DNS Configuration

```bash
# View local DNS records
ssh root@<dns-ip> "pihole-FTL --config dns.hosts"

# View upstream DNS servers
ssh root@<dns-ip> "pihole-FTL --config dns.upstreams"

# View full TOML config (truncated)
ssh root@<dns-ip> "cat /etc/pihole/pihole.toml"
```

### DNS Resolution Testing

```bash
# Query a record through Pi-hole
dig @<dns-ip> vault.<domain>

# Query with full details
dig @<dns-ip> vault.<domain> +noall +answer +authority

# Reverse lookup
dig @<dns-ip> -x <ip-address>

# Test Samba AD DNS forwarding
dig @<dns-ip> _ldap._tcp.ad.<domain> SRV

# Use nslookup
nslookup vault.<domain> <dns-ip>

# Test DNS from a specific node
ssh user@<nomad01-ip> "dig @<dns-ip> vault.<domain>"
```

---

## Step-CA (Certificate Authority)

### Health Check

```bash
# Check step-ca health
curl -k https://ca.<domain>/health

# Check step-ca ACME directory
curl -k https://ca.<domain>/acme/acme/directory | jq .
```

### Certificate Inspection

```bash
# View the root CA certificate
openssl x509 -in crypto/root_ca.crt -text -noout

# Check root CA expiry
openssl x509 -in crypto/root_ca.crt -noout -enddate

# Check a service certificate
openssl s_client -connect vault.<domain>:443 -servername vault.<domain> </dev/null 2>/dev/null | openssl x509 -text -noout

# Verify the certificate chain against the root CA
openssl s_client -connect vault.<domain>:443 -CAfile crypto/root_ca.crt -servername vault.<domain> </dev/null

# Check certificate expiry for a service
openssl s_client -connect vault.<domain>:443 -servername vault.<domain> </dev/null 2>/dev/null | openssl x509 -noout -enddate
```

### acme.sh on Nodes

```bash
# List certificates on a Nomad node
ssh user@<nomad01-ip> "acme.sh --list"

# Check certificate details
ssh user@<nomad01-ip> "acme.sh --info -d <hostname>.<domain>"
```

---

## GlusterFS

### Volume Status

```bash
# Check volume status (run on any Nomad node)
ssh user@<nomad01-ip> "sudo gluster volume status nomad-data"

# View volume info
ssh user@<nomad01-ip> "sudo gluster volume info nomad-data"

# Check peer status
ssh user@<nomad01-ip> "sudo gluster peer status"

# Verify the mount
ssh user@<nomad01-ip> "df -h /srv/gluster/nomad-data"

# Check mount point is accessible
ssh user@<nomad01-ip> "ls -la /srv/gluster/nomad-data/"
```

### Heal Status

```bash
# Check if any files need healing
ssh user@<nomad01-ip> "sudo gluster volume heal nomad-data info"

# Check for split-brain
ssh user@<nomad01-ip> "sudo gluster volume heal nomad-data info split-brain"

# Trigger a heal
ssh user@<nomad01-ip> "sudo gluster volume heal nomad-data"
```

---

## Network Connectivity

### Basic Connectivity

```bash
# Ping a node
ping -c 3 <ip-address>

# Check if a port is open
nc -zv <ip-address> <port>

# Test SSH connectivity
ssh -o ConnectTimeout=5 -i crypto/lab-deploy user@<ip-address> "echo ok"
```

### Service Port Checks

```bash
# Nomad API
nc -zv <nomad01-ip> 4646

# Vault
nc -zv <nomad01-ip> 8200

# Traefik HTTP
nc -zv <nomad01-ip> 80

# Traefik HTTPS
nc -zv <nomad01-ip> 443

# Traefik Dashboard
nc -zv <nomad01-ip> 8081

# Pi-hole DNS
nc -zv <dns-ip> 53

# Pi-hole Web
nc -zv <dns-ip> 80

# Step-CA HTTPS
nc -zv <ca-ip> 443

# Samba AD LDAP
nc -zv <nomad01-ip> 389

# Samba AD Kerberos
nc -zv <nomad01-ip> 88

# Proxmox API
nc -zv <proxmox-ip> 8006
```

---

## Samba AD

### Domain Controller Status

```bash
# Check container is running (on nomad01)
ssh user@<nomad01-ip> "docker ps | grep samba"

# View DC logs
docker compose run --rm nomad alloc logs -job samba-dc

# Check replication status (inside DC01 container)
ssh user@<nomad01-ip> "docker exec <samba-dc01-container> samba-tool drs showrepl"

# List domain users
ssh user@<nomad01-ip> "docker exec <samba-dc01-container> samba-tool user list"

# Test LDAP
ldapsearch -H ldap://<nomad01-ip>:389 -b "dc=ad,dc=mylab,dc=lan" -x

# Test Kerberos
dig @<nomad01-ip> -p 5353 _kerberos._tcp.ad.<domain> SRV
```

---

## Proxmox Host

### VM and LXC Status

```bash
# List all VMs
ssh root@<proxmox-ip> "qm list"

# List all LXC containers
ssh root@<proxmox-ip> "pct list"

# Check a specific VM status
ssh root@<proxmox-ip> "qm status <vmid>"

# Check a specific LXC status
ssh root@<proxmox-ip> "pct status <vmid>"

# View VM configuration
ssh root@<proxmox-ip> "qm config <vmid>"
```

### Storage Status

```bash
# List storage
ssh root@<proxmox-ip> "pvesm status"

# Check disk usage
ssh root@<proxmox-ip> "df -h"
```

### Cluster Status (multi-node)

```bash
# Check cluster status
ssh root@<proxmox-ip> "pvecm status"

# List cluster nodes
ssh root@<proxmox-ip> "pvecm nodes"
```

---

## Authentik

### Service Status

```bash
# Check via Traefik
curl -sk https://auth.<domain>/api/v3/root/config/ | jq .

# View logs
docker compose run --rm nomad alloc logs -job authentik
```

---

## Quick Health Check Script

Run these commands in sequence for a rapid overall health assessment:

```bash
# 1. Nomad cluster
docker compose run --rm nomad server members
docker compose run --rm nomad node status
docker compose run --rm nomad job status

# 2. Vault
curl -s http://<nomad01-ip>:8200/v1/sys/health | jq '{initialized, sealed, version}'

# 3. Traefik
curl -s http://<nomad01-ip>:8081/api/overview | jq .

# 4. DNS
dig @<dns-ip> vault.<domain> +short

# 5. Step-CA
curl -sk https://ca.<domain>/health

# 6. GlusterFS
ssh user@<nomad01-ip> "sudo gluster volume status nomad-data" 2>/dev/null | head -5
```
