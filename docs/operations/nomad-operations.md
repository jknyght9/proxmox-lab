# Nomad Operations

Daily operations guide for managing the Nomad cluster and deploying jobs.

## Accessing Nomad

### Web UI

URL: `http://nomad01.mylab.lan:4646`

Features:
- Job status and history
- Allocation logs
- Node health
- Service registry
- Evaluation details

### SSH Access

```bash
ssh ubuntu@nomad01.mylab.lan
# or nomad02, nomad03
```

### Docker CLI

For interactive commands, use the Docker Compose wrapper:

```bash
# From project root
docker compose run --rm nomad job status
docker compose run --rm nomad node status
```

Update `NOMAD_ADDR` in `docker-compose.yml` if needed.

## Cluster Management

### Check Cluster Status

```bash
# Server members
nomad server members

# Expected output:
Name             Address      Port  Status  Leader  Raft Version  Build   Datacenter  Region
nomad01.global  10.1.50.114  4648  alive   true    3             1.7.0   dc1         global
nomad02.global  10.1.50.115  4648  alive   false   3             1.7.0   dc1         global
nomad03.global  10.1.50.116  4648  alive   false   3             1.7.0   dc1         global
```

### Check Node Status

```bash
# List all nodes
nomad node status

# Detailed node info
nomad node status <node-id>

# Node resource usage
nomad node status -stats <node-id>
```

### Check Raft Peers

```bash
nomad operator raft list-peers

# Expected: 3 peers, one leader
```

## Job Management

### Listing Jobs

```bash
# All jobs
nomad job status

# Specific job
nomad job status vault

# Compact output
nomad job status -short
```

### Deploying Jobs

```bash
# Run job from file
nomad job run /path/to/job.nomad.hcl

# Run with variables
nomad job run -var='replicas=3' job.nomad.hcl

# Dry run (plan)
nomad job plan job.nomad.hcl
```

### Stopping Jobs

```bash
# Stop job (keep in history)
nomad job stop vault

# Stop and purge (remove from history)
nomad job stop -purge vault

# Force stop (skip graceful shutdown)
nomad job stop -detach vault
```

### Viewing Job Details

```bash
# Job specification
nomad job inspect vault

# Job history
nomad job history vault

# Deployments
nomad job deployments vault
```

## Allocation Management

### Viewing Allocations

```bash
# List allocations for a job
nomad job status vault

# Allocation details
nomad alloc status <alloc-id>

# Allocation logs
nomad alloc logs <alloc-id>

# Follow logs in real-time
nomad alloc logs -f <alloc-id>

# Logs for specific task
nomad alloc logs -task server <alloc-id>
```

### Restarting Allocations

```bash
# Restart specific allocation
nomad alloc restart <alloc-id>

# Restart specific task
nomad alloc restart -task worker <alloc-id>
```

### Exec into Allocation

```bash
# Open shell in allocation
nomad alloc exec -task server <alloc-id> /bin/sh

# Run command
nomad alloc exec <alloc-id> ps aux
```

## Service Registry

### Listing Services

```bash
# All registered services
nomad service list

# Services for specific job
nomad job status vault | grep -A 10 "Services"
```

### Service Details

```bash
# Query service info
nomad service info vault

# JSON output for scripting
nomad service info -json vault | jq .
```

## Monitoring and Debugging

### Check System Health

```bash
# Garbage collection status
nomad system gc

# Reconcile job summaries
nomad system reconcile summaries
```

### View Evaluations

```bash
# List evaluations
nomad eval list

# Evaluation details
nomad eval status <eval-id>
```

### Node Drain

```bash
# Drain node for maintenance
nomad node drain -enable -yes <node-id>

# Check drain status
nomad node status <node-id>

# Re-enable node
nomad node drain -disable <node-id>
```

### Node Eligibility

```bash
# Mark node ineligible for scheduling
nomad node eligibility -disable <node-id>

# Re-enable
nomad node eligibility -enable <node-id>
```

## Common Operations

### Deploying Vault

```bash
./setup.sh
# Select option 8: Deploy Vault secrets manager (on Nomad)

# Or manually:
nomad job run nomad/jobs/vault.nomad.hcl
```

### Deploying Authentik

```bash
./setup.sh
# Select option 9: Deploy Authentik SSO (on Nomad)

# Or manually (ensure secrets in Vault first):
nomad job run nomad/jobs/authentik.nomad.hcl
```

### Deploying Traefik

```bash
./setup.sh
# Select option 7: Deploy Traefik load balancer (on Nomad)

# Or manually:
nomad job run nomad/jobs/traefik.nomad.hcl
```

### Redeploying a Job

```bash
# Stop and purge old job
nomad job stop -purge vault

# Deploy new version
nomad job run nomad/jobs/vault.nomad.hcl

# Monitor deployment
nomad job status vault
```

### Viewing Logs

```bash
# Latest logs
nomad alloc logs -job vault

# Follow logs
nomad alloc logs -f -job vault

# Stderr only
nomad alloc logs -stderr -job vault

# Last 50 lines
nomad alloc logs -tail -n 50 -job vault
```

## GlusterFS Operations

### Check Volume Status

```bash
ssh ubuntu@nomad01

# Volume status
sudo gluster volume status nomad-data

# Volume info
sudo gluster volume info nomad-data

# Peer status
sudo gluster peer status
```

### Heal Operations

```bash
# Check for files needing heal
sudo gluster volume heal nomad-data info

# Check heal status
sudo gluster volume heal nomad-data info healed

# Trigger full heal
sudo gluster volume heal nomad-data full
```

### Mount Issues

```bash
# Check if mounted
df -h | grep nomad-data

# Remount
sudo umount /srv/gluster/nomad-data
sudo mount -t glusterfs nomad01:/nomad-data /srv/gluster/nomad-data

# Check fstab entry
cat /etc/fstab | grep nomad-data
```

## Troubleshooting

### Job Won't Start

```bash
# Check allocation events
nomad alloc status <alloc-id>

# Check for errors in logs
nomad alloc logs <alloc-id>

# Check node resources
nomad node status -stats
```

### Port Already in Use

```bash
# Find conflicting allocation
nomad job status -all-allocs

# Stop old allocations
nomad job stop -purge <old-job>
```

### Service Not Registered

```bash
# Check job service block
nomad job inspect <job-name> | jq '.Job.TaskGroups[].Services'

# Verify provider is set
# Should have: provider = "nomad"

# Check Nomad service list
nomad service list
```

### Node Unresponsive

```bash
# SSH to node and check Nomad service
ssh ubuntu@nomad02
sudo systemctl status nomad

# Restart Nomad
sudo systemctl restart nomad

# Check logs
sudo journalctl -u nomad -f
```

### Raft Issues

```bash
# Check Raft peers
nomad operator raft list-peers

# If split brain or no leader, may need to recover
# (Rare - consult Nomad docs for recovery procedures)
```

## Best Practices

### Job Deployment

1. Always use `nomad job plan` before `nomad job run`
2. Use version control for job files
3. Test in development before production
4. Use constraints to control placement
5. Set appropriate resource limits

### Resource Management

1. Monitor node resource usage
2. Set realistic CPU/memory requests
3. Use `resources` block in all tasks
4. Plan for peak load + headroom

### Service Registration

1. Always set `provider = "nomad"` for Traefik discovery
2. Use meaningful service names
3. Configure health checks
4. Tag services appropriately

### Maintenance

1. Drain nodes before maintenance
2. Verify job status after node returns
3. Keep Nomad version consistent across cluster
4. Backup GlusterFS data regularly

## Automation

### Checking Job Health

```bash
#!/bin/bash
# check-nomad-jobs.sh

for job in traefik vault authentik; do
  status=$(nomad job status -short $job | grep -c running)
  if [ "$status" -eq 0 ]; then
    echo "CRITICAL: $job is not running"
    # Send alert
  fi
done
```

### Restarting Failed Allocations

```bash
#!/bin/bash
# restart-failed.sh

nomad job status -short | grep failed | awk '{print $1}' | while read job; do
  echo "Restarting $job"
  nomad job stop -purge $job
  nomad job run "nomad/jobs/${job}.nomad.hcl"
done
```

## Next Steps

- [:octicons-arrow-right-24: Vault Operations](vault-operations.md)
- [:octicons-arrow-right-24: Nomad Module](../modules/nomad.md)
- [:octicons-arrow-right-24: Troubleshooting](../troubleshooting/common-issues.md)
