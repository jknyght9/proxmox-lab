# Nomad Operations

This page covers day-to-day Nomad cluster operations, including CLI usage through Docker Compose, job management, cluster health monitoring, and GlusterFS volume management.

---

## Nomad CLI via Docker Compose

All Nomad commands are run through Docker Compose from the project root. The container is pre-configured with the correct `NOMAD_ADDR` environment variable.

```bash
docker compose run --rm nomad <command>
```

!!! note "NOMAD_ADDR"
    The Nomad address is configured in `compose.yml`. If your nomad01 IP differs from the default (`192.168.1.50`), update the `NOMAD_ADDR` environment variable in `compose.yml`.

---

## Common Commands

### Job Management

```bash
# List all jobs and their status
docker compose run --rm nomad job status

# View detailed status for a specific job
docker compose run --rm nomad job status vault

# Deploy a job from a file
docker compose run --rm nomad job run /nomad/jobs/vault.nomad.hcl

# Plan a job (dry-run, shows what will change)
docker compose run --rm nomad job plan /nomad/jobs/vault.nomad.hcl

# Stop a running job
docker compose run --rm nomad job stop vault

# Stop and completely purge a job (removes all history)
docker compose run --rm nomad job stop -purge vault
```

### Viewing Logs

```bash
# View logs for the most recent allocation of a job
docker compose run --rm nomad alloc logs -job vault

# View stderr logs
docker compose run --rm nomad alloc logs -job vault -stderr

# Follow logs in real time
docker compose run --rm nomad alloc logs -job vault -f

# View logs for a specific allocation (use alloc ID from job status)
docker compose run --rm nomad alloc logs <alloc-id>
```

### Service Discovery

```bash
# List all registered services
docker compose run --rm nomad service list

# View details for a specific service
docker compose run --rm nomad service info <service-name>
```

### Cluster Health

```bash
# View server members and leader status
docker compose run --rm nomad server members

# View node (client) status
docker compose run --rm nomad node status

# View detailed status for a specific node
docker compose run --rm nomad node status <node-id>

# Check cluster operator status (raft configuration)
docker compose run --rm nomad operator raft list-peers
```

---

## Deploying Jobs

### Standard Deployment

To deploy a Nomad job:

```bash
# 1. Plan the job to see what will change
docker compose run --rm nomad job plan /nomad/jobs/traefik.nomad.hcl

# 2. Run the job
docker compose run --rm nomad job run /nomad/jobs/traefik.nomad.hcl

# 3. Verify the job is running
docker compose run --rm nomad job status traefik
```

### Available Jobs

| Job File | Service | Description |
|----------|---------|-------------|
| `traefik.nomad.hcl` | Traefik | Reverse proxy and load balancer |
| `vault.nomad.hcl` | Vault | Secrets management |
| `authentik.nomad.hcl` | Authentik | Identity provider (SSO) |
| `samba-dc.nomad.hcl` | Samba AD | Active Directory Domain Controllers |

### Job Constraints

All service jobs are pinned to nomad01 using a hostname constraint:

```hcl
constraint {
  attribute = "${attr.unique.hostname}"
  value     = "nomad01"
}
```

This ensures consistent DNS resolution and avoids cross-node routing complexity.

---

## Monitoring Allocations

### Allocation Lifecycle

Each job deployment creates allocations. An allocation goes through these states:

1. **Pending** -- waiting for resources
2. **Running** -- task is executing
3. **Complete** -- task finished successfully
4. **Failed** -- task exited with an error

### Inspecting Allocations

```bash
# List allocations for a job
docker compose run --rm nomad job status vault

# View detailed allocation info
docker compose run --rm nomad alloc status <alloc-id>

# View allocation events (scheduling, restarts, failures)
docker compose run --rm nomad alloc status -verbose <alloc-id>
```

### Handling Failed Allocations

If an allocation fails:

1. Check the logs for error messages:
   ```bash
   docker compose run --rm nomad alloc logs <alloc-id>
   docker compose run --rm nomad alloc logs <alloc-id> -stderr
   ```

2. Check the allocation status for scheduling issues:
   ```bash
   docker compose run --rm nomad alloc status <alloc-id>
   ```

3. If the job is stuck, stop and purge it before redeploying:
   ```bash
   docker compose run --rm nomad job stop -purge <job-name>
   docker compose run --rm nomad job run /nomad/jobs/<job-file>
   ```

---

## Cluster Health Monitoring

### Server Quorum

The Nomad cluster runs 3 server nodes. At least 2 must be healthy to maintain quorum:

```bash
# Check server members and leader
docker compose run --rm nomad server members
```

Expected output shows 3 members with one marked as `leader`:

```
Name           Address       Port  Status  Leader  Raft Version  Build   Datacenter  Region
nomad01.global 192.168.1.50   4648  alive   true    3             1.x.x   dc1         global
nomad02.global 192.168.1.51   4648  alive   false   3             1.x.x   dc1         global
nomad03.global 192.168.1.52   4648  alive   false   3             1.x.x   dc1         global
```

### Node (Client) Status

```bash
# Check all client nodes
docker compose run --rm nomad node status
```

All 3 nodes should show as `ready` and `eligible`:

```
ID        DC   Name     Class   Drain  Eligibility  Status
abc123    dc1  nomad01  <none>  false  eligible     ready
def456    dc1  nomad02  <none>  false  eligible     ready
ghi789    dc1  nomad03  <none>  false  eligible     ready
```

### Raft Consensus

```bash
# View raft peer configuration
docker compose run --rm nomad operator raft list-peers
```

This shows the Raft consensus state and which nodes are voters.

---

## GlusterFS Volume Management

The Nomad cluster uses GlusterFS for replicated storage across all 3 nodes. The shared volume is mounted at `/srv/gluster/nomad-data` on each node.

### Volume Structure

```
/srv/gluster/nomad-data/
  +-- vault/              # Vault persistent data
  +-- traefik/            # Traefik config and ACME certificates
  |     +-- acme.json     # ACME certificate store
  +-- authentik/          # Authentik data
  |     +-- postgres/     # PostgreSQL database
  |     +-- redis/        # Redis cache
  +-- samba-dc01/         # Primary Samba DC data
  +-- samba-dc02/         # Secondary Samba DC data
```

### Checking GlusterFS Status

SSH into any Nomad node to check GlusterFS:

```bash
# Check volume status
sudo gluster volume status nomad-data

# Check volume info
sudo gluster volume info nomad-data

# Check peer status
sudo gluster peer status

# Verify the mount
df -h /srv/gluster/nomad-data
```

### Common GlusterFS Issues

**Volume not mounted:**

```bash
# Remount the volume
sudo mount -t glusterfs localhost:/nomad-data /srv/gluster/nomad-data
```

**Split-brain or heal needed:**

```bash
# Check heal status
sudo gluster volume heal nomad-data info

# Trigger a heal
sudo gluster volume heal nomad-data
```

**Stale data from a previous deployment:**

```bash
# Clean up a service directory (e.g., Vault)
sudo rm -rf /srv/gluster/nomad-data/vault/*
```

!!! warning
    Clearing service data is destructive. Only do this when you intend to redeploy the service from scratch. For Vault, this means reinitializing and generating new unseal keys.

---

## Restarting Services

### Restart a Single Job

```bash
# Stop and redeploy
docker compose run --rm nomad job stop <job-name>
docker compose run --rm nomad job run /nomad/jobs/<job-file>
```

### Restart with Purge

If a job has stale allocations or failed deployments:

```bash
docker compose run --rm nomad job stop -purge <job-name>
docker compose run --rm nomad job run /nomad/jobs/<job-file>
```

### Deployment Order

When deploying all services, follow this order due to dependencies:

1. **Traefik** -- reverse proxy must be running first
2. **Vault** -- secrets manager needed by other services
3. **Authentik** -- depends on Vault for secrets
4. **Samba AD** -- depends on Vault for secrets

---

## Nomad UI

The Nomad web UI is available at `http://<nomad01-ip>:4646` and provides:

- **Jobs view**: see all jobs, their status, and recent deployments
- **Allocations**: drill into individual allocations for logs and events
- **Topology**: visual representation of the cluster and resource usage
- **Server status**: view leader election and server health

The UI is a convenient alternative to the CLI for monitoring and troubleshooting, though deployments should be done through the CLI to ensure reproducibility.
