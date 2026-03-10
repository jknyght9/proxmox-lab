# Common Issues

This page covers frequently encountered issues and their solutions.

## DNS Issues

### DNS Records Not Resolving

**Symptoms:**
- Services like `vault.mylab.lan` don't resolve
- `nslookup` or `dig` queries fail
- Browser shows "DNS_PROBE_FINISHED_NXDOMAIN"

**Causes & Solutions:**

1. **DNS server not configured on client**

   ```bash
   # Check your DNS server
   # macOS/Linux:
   cat /etc/resolv.conf
   # Windows:
   ipconfig /all
   ```

   **Fix:** Configure your client to use dns-01 IP address as DNS server.

2. **DNS container not running**

   ```bash
   # Check container status
   pct status 910  # dns-01

   # If stopped, start it
   pct start 910
   ```

3. **Records not added to Pi-hole**

   ```bash
   # Run DNS update
   ./setup.sh
   # Select option 10: Build DNS records
   ```

   Or check manually:
   ```bash
   ssh root@<dns-01-ip>
   pihole-FTL --config dns.hosts get
   ```

### Local Domains Resolve but External Don't

**Symptoms:**
- `vault.mylab.lan` resolves correctly
- `google.com` fails or times out

**Causes:**

1. **Unbound or dnscrypt-proxy not running**

   ```bash
   ssh root@dns-01
   systemctl status unbound
   systemctl status dnscrypt-proxy
   ```

   **Fix:**
   ```bash
   systemctl restart unbound
   systemctl restart dnscrypt-proxy
   systemctl restart pihole-FTL
   ```

2. **Upstream DNS blocked by firewall**

   Pi-hole uses DNS-over-HTTPS (port 443). Verify outbound HTTPS is allowed.

### Tailscale Overwriting DNS Configuration

**Symptoms:**
- `/etc/resolv.conf` on Proxmox nodes shows `nameserver 100.100.100.100`
- Local `.mylab.lan` domains don't resolve on Proxmox nodes
- DNS configuration resets after reboot
- Manually editing `/etc/resolv.conf` doesn't persist

**Cause:**

Tailscale MagicDNS automatically manages DNS configuration by:
- Overwriting `/etc/resolv.conf` with Tailscale's DNS server (100.100.100.100)
- Restoring this configuration on boot or network changes
- Preventing manual DNS settings from persisting

**Solution:**

Run the DNS update process which automatically disables Tailscale DNS management:

```bash
./setup.sh
# Select option 10: Build DNS records
# Answer Y when prompted to update Proxmox DNS
```

This runs `tailscale set --accept-dns=false` on each node, preventing Tailscale from managing DNS.

**Manual Fix (per node):**

```bash
# SSH to the affected Proxmox node
ssh root@proxmox-node

# Disable Tailscale DNS management
tailscale set --accept-dns=false

# Verify the change
tailscale status
# Look for: Accept DNS: false

# Update resolv.conf
cat > /etc/resolv.conf << EOF
nameserver 10.1.50.3    # dns-01
nameserver 1.1.1.1       # Cloudflare fallback
EOF

# Verify resolution works
dig vault.mylab.lan
```

**Verify the Fix:**

```bash
# Check resolv.conf shows your DNS, not 100.100.100.100
cat /etc/resolv.conf

# Check Tailscale status
tailscale status
# Should show: "Accept DNS: false"

# Test local domain resolution
ping vault.mylab.lan
```

**Note on MagicDNS Names:**

After disabling Tailscale DNS, MagicDNS names (e.g., `node.tailnet.ts.net`) won't resolve on Proxmox nodes. Use these alternatives:

- **Use Tailscale IPs:** `ssh 100.x.x.x` instead of `ssh node.tailnet.ts.net`
- **Add to Pi-hole:** Add Tailscale hosts to Pi-hole DNS records
- **Use /etc/hosts:** Add static entries to individual nodes if needed

See [Tailscale Integration](../architecture/network-topology.md#tailscale-integration) for more details.

### DNS Changes Not Syncing to Replicas

**Symptoms:**
- Records work on dns-01 but not dns-02 or dns-03
- Nebula-Sync service shows errors

**Solution:**

1. **Trigger manual sync:**

   ```bash
   ssh root@dns-01
   systemctl start nebula-sync.service
   systemctl status nebula-sync.service
   ```

2. **Check replica connectivity:**

   ```bash
   ssh root@dns-01
   ping <dns-02-ip>
   ssh root@<dns-02-ip> 'systemctl status pihole-FTL'
   ```

3. **View sync logs:**

   ```bash
   journalctl -u nebula-sync.service -n 50
   ```

4. **Restart Nebula-Sync:**

   ```bash
   systemctl restart nebula-sync.service
   ```

## Nomad Issues

### Nomad Jobs Not Starting

**Symptoms:**
- `nomad job status` shows job as pending
- Allocations fail immediately

**Common Causes:**

1. **No eligible nodes:**

   ```bash
   nomad job status <job-name>
   # Look for "Placement Failures" section
   ```

   **Fix:** Check node constraints in the job file match available nodes.

2. **Insufficient resources:**

   ```bash
   nomad node status
   # Check available CPU/memory
   ```

   **Fix:** Reduce job resource requirements or scale up cluster.

3. **GlusterFS volume not mounted:**

   ```bash
   ssh ubuntu@nomad01
   df -h | grep gluster
   mount | grep gluster
   ```

   **Fix:**
   ```bash
   sudo systemctl restart glusterd
   sudo mount -a
   ```

### Vault Job Fails with Permission Errors

**Symptoms:**
- Vault allocation fails with "permission denied" on `/data/vault`
- Logs show storage access errors

**Cause:**

GlusterFS volumes require privileged mode for some operations.

**Solution:**

Ensure the Vault job has `privileged = true` in the Docker config:

```hcl
config {
  image = "hashicorp/vault:latest"
  privileged = true  # Required for GlusterFS
  ...
}
```

Clean up old data and restart:

```bash
# On nomad01
sudo rm -rf /srv/gluster/nomad-data/vault/*

# Restart job
docker compose run --rm nomad job stop -purge vault
docker compose run --rm nomad job run /nomad/jobs/vault.nomad.hcl
```

### Services Not Accessible via Traefik

**Symptoms:**
- Service DNS resolves correctly
- Traefik dashboard shows service as healthy
- HTTP requests timeout or return 404

**Troubleshooting:**

1. **Check Traefik routers:**

   ```bash
   curl http://nomad01:8081/api/http/routers | jq .
   ```

   Verify your service has a router with the correct Host rule.

2. **Check service is running:**

   ```bash
   docker compose run --rm nomad job status <job-name>
   docker compose run --rm nomad alloc logs -job <job-name>
   ```

3. **Verify service registration:**

   ```bash
   docker compose run --rm nomad service list
   ```

   Your service should appear with the correct tags.

4. **Check Nomad provider connection:**

   ```bash
   # In Traefik logs
   docker compose run --rm nomad alloc logs -job traefik
   # Look for connection to Nomad API at 127.0.0.1:4646
   ```

## Certificate Issues

### ACME Challenges Failing

**Symptoms:**
- Certificate requests fail
- step-ca logs show challenge validation errors
- Traefik shows "unable to obtain certificate"

**Causes & Solutions:**

1. **DNS not resolving to correct host:**

   ```bash
   dig vault.mylab.lan
   # Should return nomad01 IP
   ```

   **Fix:** Run DNS update (setup.sh option 10).

2. **Port 80 not accessible:**

   HTTP-01 challenges require port 80 to be accessible.

   ```bash
   curl http://nomad01/
   # Should reach Traefik
   ```

3. **Root CA not trusted:**

   ```bash
   # On the host requesting certs
   curl https://ca.mylab.lan/health
   # Should return {"status":"ok"} without SSL errors
   ```

   **Fix:** Install root CA certificate (see [Certificate Operations](../operations/certificate-operations.md)).

### Proxmox Web UI Shows Certificate Errors

**Symptoms:**
- Browser warns about invalid certificate
- Certificate is self-signed

**Solution:**

Re-run certificate installation:

```bash
./setup.sh
# Select option 12: Update root certificates
```

This pushes the step-ca root certificate to Proxmox and installs valid TLS certs.

## Terraform Issues

### Resources Already Exist

**Symptoms:**
- `terraform apply` fails with "resource already exists"
- Trying to create VM/LXC that's already deployed

**Solution:**

**Option 1: Import existing resources**
```bash
cd terraform
docker compose run terraform import module.vm-nomad.proxmox_vm_qemu.nomad_node[0] 905
```

**Option 2: Destroy and recreate**
```bash
./setup.sh
# Select option 13: Rollback (Terraform destroy)
# Then re-run deployment
```

**Option 3: Emergency purge**
```bash
./setup.sh
# Select option 14: Purge (Emergency)
# Directly destroys VMs via SSH, use only if Terraform is broken
```

### API Token Authentication Failed

**Symptoms:**
- Terraform/Packer fails with "401 Unauthorized"
- "authentication failure" errors

**Solution:**

1. **Verify token exists in Proxmox:**
   - Login to Proxmox web UI
   - Go to Datacenter > Permissions > API Tokens
   - Check that `terraform@pam!terraform-token` exists

2. **Regenerate token:**
   ```bash
   ./setup.sh
   # Select option 1 or 2: New installation
   # This recreates the API token
   ```

3. **Verify credentials in config files:**
   - `packer/packer.auto.pkrvars.hcl`
   - `terraform/terraform.tfvars`

   Both should have matching token ID and secret.

## Packer Issues

### Base Template (VMID 9999) Not Found

**Symptoms:**
- Packer fails with "VM 9999 does not exist"
- Can't build Docker or Nomad templates

**Solution:**

Download and configure the Ubuntu 24.04 base template:

1. **Download from Ubuntu:**
   ```bash
   wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
   ```

2. **Create VM in Proxmox:**
   ```bash
   qm create 9999 --name ubuntu-base --memory 2048 --net0 virtio,bridge=vmbr0
   qm importdisk 9999 noble-server-cloudimg-amd64.img local-lvm
   qm set 9999 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9999-disk-0
   qm set 9999 --ide2 local-lvm:cloudinit
   qm set 9999 --boot c --bootdisk scsi0
   qm set 9999 --serial0 socket --vga serial0
   qm template 9999
   ```

3. **Verify template:**
   ```bash
   qm list | grep 9999
   ```

### Packer Build Times Out

**Symptoms:**
- Packer hangs at "Waiting for SSH to become available"
- Build never completes

**Causes:**

1. **SSH not enabled on template**
2. **Network configuration incorrect**
3. **Cloud-init not running**

**Solution:**

Check the VM console in Proxmox to see boot messages:
- Click on the building VM in Proxmox UI
- Go to Console
- Look for cloud-init completion
- Verify network configuration

## Vault Issues

### Vault is Sealed

**Symptoms:**
- Vault returns "503 Service Unavailable"
- Web UI shows "Vault is sealed"
- API calls fail

**Cause:**

Vault seals itself on restart for security. This is normal behavior.

**Solution:**

Unseal using the key from `crypto/vault-credentials.json`:

```bash
# Get unseal key
UNSEAL_KEY=$(jq -r '.unseal_key' crypto/vault-credentials.json)

# Unseal Vault
curl -X PUT http://nomad01:8200/v1/sys/unseal \
  -d "{\"key\": \"$UNSEAL_KEY\"}"

# Verify status
curl http://nomad01:8200/v1/sys/health
```

**Automated unseal:**
```bash
./setup.sh
# Select option for Vault operations
# Includes unseal option
```

### Vault Nomad Integration Not Working

**Symptoms:**
- Jobs fail with "failed to derive Vault token"
- Workload Identity authentication errors

**Solution:**

1. **Verify JWT auth is configured:**
   ```bash
   # List auth methods
   curl -H "X-Vault-Token: $ROOT_TOKEN" \
     http://nomad01:8200/v1/sys/auth
   ```

2. **Re-configure integration:**
   ```bash
   ./setup.sh
   # Deploy Vault job - includes WIF configuration
   ```

3. **Check Nomad identity block:**
   Ensure job has:
   ```hcl
   identity {
     env  = true
     file = true
   }

   vault {
     role = "service-role-name"
   }
   ```

## Connectivity Issues

### Can't SSH to VMs

**Symptoms:**
- SSH connection refused or times out
- "Connection timed out" errors

**Troubleshooting:**

1. **Verify VM is running:**
   ```bash
   qm status <vmid>
   ```

2. **Check IP address:**
   - View in Proxmox UI under VM > Summary
   - Or use `qm guest cmd <vmid> network-get-interfaces`

3. **Verify network configuration:**
   ```bash
   # Console into VM from Proxmox UI
   # Check network:
   ip addr show
   ip route show
   ```

4. **Test from Proxmox host:**
   ```bash
   # From Proxmox
   ping <vm-ip>
   ssh ubuntu@<vm-ip>
   ```

### Can't Access Labnet (SDN) Resources

**Symptoms:**
- Can't reach 172.16.0.x addresses from external network
- Labnet VMs can't reach external services

**Cause:**

Labnet is an isolated SDN network. Cross-network access requires special configuration.

**Solutions:**

1. **Use Kasm as jump host** (Kasm is dual-homed on both networks)
2. **Configure routing on Proxmox**
3. **Set up VPN on a labnet VM**
4. **Access via pct exec for LXC containers:**
   ```bash
   pct exec 920 -- <command>
   ```

## Performance Issues

### High CPU Usage on Nomad Nodes

**Check what's running:**
```bash
docker compose run --rm nomad node status -verbose
docker compose run --rm nomad alloc status
```

**Common causes:**
- Too many jobs on one node
- Resource limits too low causing thrashing
- GlusterFS replication activity

### GlusterFS Performance Issues

**Check volume status:**
```bash
ssh ubuntu@nomad01
sudo gluster volume info
sudo gluster volume status nomad-data
```

**Check replication:**
```bash
sudo gluster volume heal nomad-data info
```

**Optimize performance:**
```bash
sudo gluster volume set nomad-data performance.cache-size 256MB
sudo gluster volume set nomad-data performance.write-behind on
```

## Getting Help

If you've tried these solutions and still have issues:

1. **Check logs:**
   - Nomad: `docker compose run --rm nomad alloc logs -job <job>`
   - Proxmox: `journalctl -u pve* -f`
   - DNS: `ssh root@dns-01 journalctl -u pihole-FTL -f`

2. **Review documentation:**
   - [Architecture Overview](../architecture/overview.md)
   - [Network Topology](../architecture/network-topology.md)
   - [DNS Management](../operations/dns-management.md)

3. **Check GitHub Issues:**
   [github.com/jknyght9/proxmox-lab/issues](https://github.com/jknyght9/proxmox-lab/issues)

4. **Enable debug logging:**
   ```bash
   # For Terraform
   export TF_LOG=DEBUG

   # For Nomad
   docker compose run --rm nomad monitor
   ```
