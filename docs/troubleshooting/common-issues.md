# Common Issues

This page covers the most frequently encountered issues in Proxmox Lab, organized by service. For specific error messages, see [Error Reference](error-reference.md). For diagnostic commands, see [Diagnostic Commands](diagnostic-commands.md).

---

## Vault Issues

### Permission Denied on Storage

**Symptom:** Vault fails to start with permission errors writing to the storage backend.

**Cause:** The Docker container does not have sufficient permissions to write to the GlusterFS volume.

**Solution:**

1. Verify that `privileged = true` is set in the Vault Nomad job Docker config
2. Clean up stale data from a previous deployment:

```bash
ssh user@<nomad01-ip> "sudo rm -rf /srv/gluster/nomad-data/vault/*"
```

3. Restart the Vault job:

```bash
docker compose run --rm nomad job stop -purge vault
docker compose run --rm nomad job run /nomad/jobs/vault.nomad.hcl
```

### Port Already in Use

**Symptom:** Vault job fails with a "port already in use" or "address already in use" error.

**Cause:** A previous Vault allocation is still running or did not clean up properly.

**Solution:**

```bash
# Stop and purge all allocations
docker compose run --rm nomad job stop -purge vault

# Wait a few seconds, then redeploy
docker compose run --rm nomad job run /nomad/jobs/vault.nomad.hcl
```

If the port is still in use after purging, SSH into nomad01 and check for stale Docker containers:

```bash
ssh user@<nomad01-ip> "docker ps -a | grep vault"
# If found, remove manually:
ssh user@<nomad01-ip> "docker rm -f <container-id>"
```

### Vault Not Responding

**Symptom:** Vault UI is unreachable or API requests time out.

**Cause:** Vault may be running on a different node than expected, or the job may have failed.

**Solution:**

1. Check which node Vault is running on:
   ```bash
   docker compose run --rm nomad job status vault
   ```
2. Verify the allocation is in `running` state
3. Check all Nomad node IPs -- Vault should be on nomad01 due to the hostname constraint
4. Check Vault logs for errors:
   ```bash
   docker compose run --rm nomad alloc logs -job vault
   ```

### Vault is Sealed

**Symptom:** Vault returns HTTP 503 and the UI shows an unseal prompt.

**Cause:** Vault seals itself on restart. This happens after any job restart, node reboot, or container recreation.

**Solution:** See [Backup & Recovery - Vault Unseal](../operations/backup-recovery.md#vault-unseal-after-restart).

---

## Traefik Issues

### 404 Errors for Services

**Symptom:** Accessing a service through Traefik returns a 404 page.

**Cause:** Traefik has not discovered the service, or the router configuration is incorrect.

**Solution:**

1. Check the Traefik API for registered routers:
   ```bash
   curl http://<nomad01-ip>:8081/api/http/routers | jq .
   ```

2. Verify the service is registered in Nomad:
   ```bash
   docker compose run --rm nomad service list
   ```

3. Check that the Nomad job has the correct `tags` for Traefik service discovery (e.g., `traefik.http.routers.<name>.rule`)

4. Verify DNS resolves the service hostname to nomad01:
   ```bash
   dig @<dns-ip> vault.<domain>
   ```

### ACME Challenge Failures

**Symptom:** Traefik logs show ACME challenge errors, and services do not get TLS certificates.

**Cause:** DNS does not resolve the service hostname to the Traefik node, or the step-ca ACME endpoint is unreachable.

**Solution:**

1. Verify DNS resolves to the Traefik node (nomad01):
   ```bash
   dig @<dns-ip> vault.<domain>
   ```

2. Check that step-ca is running:
   ```bash
   curl -k https://ca.<domain>/health
   ```

3. Clear the stale ACME store and restart Traefik:
   ```bash
   ssh user@<nomad01-ip> "sudo rm /srv/gluster/nomad-data/traefik/acme.json"
   docker compose run --rm nomad job stop -purge traefik
   docker compose run --rm nomad job run /nomad/jobs/traefik.nomad.hcl
   ```

### Service Not Discovered by Traefik

**Symptom:** A Nomad job is running but Traefik does not proxy traffic to it.

**Cause:** The service is not registered in Nomad's service catalog, or Traefik's Nomad provider is not configured correctly.

**Solution:**

1. Verify the service is listed in Nomad:
   ```bash
   docker compose run --rm nomad service list
   ```

2. Check the Nomad job definition for a `service` stanza with Traefik tags

3. Verify Traefik can reach Nomad's API:
   ```bash
   # From inside the Traefik container, it uses http://127.0.0.1:4646
   docker compose run --rm nomad alloc logs -job traefik | grep -i nomad
   ```

---

## DNS Issues

### FQDN Not Resolving

**Symptom:** A fully qualified domain name (e.g., `vault.jdclabs.lan`) does not resolve, but the service is accessible by IP.

**Cause:** The DNS record is missing from Pi-hole, or the client is not using Pi-hole as its DNS server.

**Solution:**

1. Verify the record exists in Pi-hole:
   ```bash
   ssh root@<dns-ip> "pihole-FTL --config dns.hosts"
   ```

2. If missing, rebuild DNS records:
   ```bash
   ./setup.sh
   # Select option 10: Build DNS records
   ```

3. Verify your client is using Pi-hole for DNS:
   ```bash
   # Check current DNS servers
   cat /etc/resolv.conf        # Linux
   scutil --dns                 # macOS
   ```

### Short Name Resolves but FQDN Does Not

**Symptom:** `vault` resolves but `vault.jdclabs.lan` does not.

**Cause:** The search domain is set but the FQDN record is missing, or the record format is incorrect in Pi-hole.

**Solution:**

1. Check the Pi-hole local DNS entries for both short name and FQDN
2. Ensure the `dns.hosts` entry uses the full FQDN:
   ```
   "10.1.50.114 vault.jdclabs.lan"
   ```

### Service DNS Missing After Deployment

**Symptom:** You deployed a new service but its DNS record does not exist.

**Cause:** DNS records are not automatically created when services deploy. They must be added via setup.sh.

**Solution:**

```bash
./setup.sh
# Select option 10: Build DNS records
```

---

## Samba AD Issues

### Domain Controller Will Not Start

**Symptom:** The Samba DC job fails to start or crashes on startup.

**Cause:** GlusterFS mount issues, port conflicts, or missing Vault secrets.

**Solution:**

1. Check the container logs:
   ```bash
   docker compose run --rm nomad alloc logs -job samba-dc
   ```

2. Verify GlusterFS is mounted:
   ```bash
   ssh user@<nomad01-ip> "df -h /srv/gluster/nomad-data"
   ```

3. Check that required ports are available (88, 389, 445, 5353, 5354):
   ```bash
   ssh user@<nomad01-ip> "ss -tlnp | grep -E '88|389|445|5353|5354'"
   ```

4. Verify Vault secrets exist:
   ```bash
   docker compose run --rm nomad alloc exec -job vault vault kv get secret/data/samba-ad
   ```

### Replication Failing Between DCs

**Symptom:** Changes on DC01 do not appear on DC02, or replication errors are logged.

**Cause:** Network connectivity between DCs, DNS resolution issues, or Samba replication conflicts.

**Solution:**

1. Check replication status inside the DC container:
   ```bash
   # SSH into nomad01 and exec into the Samba container
   ssh user@<nomad01-ip>
   docker exec -it <samba-dc01-container> samba-tool drs showrepl
   ```

2. Verify DNS resolution between DCs:
   ```bash
   dig @<nomad01-ip> -p 5353 samba-dc02.<ad_realm>
   ```

### Domain Join Fails

**Symptom:** A client machine cannot join the Active Directory domain.

**Cause:** DNS is not forwarding AD realm queries to the Samba DCs.

**Solution:**

1. Verify Pi-hole forwards AD queries:
   ```bash
   ssh root@<dns-ip> "cat /etc/dnsmasq.d/10-ad-forward.conf"
   ```

2. Test AD DNS resolution:
   ```bash
   dig @<dns-ip> _ldap._tcp.ad.jdclabs.lan SRV
   ```

3. If forwarding is not configured, see [DNS Management - Samba AD DNS Forwarding](../operations/dns-management.md#samba-ad-dns-forwarding).

### LDAP Connection Fails

**Symptom:** LDAP queries to the Samba DC return connection errors.

**Cause:** The Samba DC is not running, the port is blocked, or the bind DN is incorrect.

**Solution:**

Test LDAP connectivity directly:

```bash
ldapsearch -H ldap://<nomad01-ip>:389 -b "dc=ad,dc=mylab,dc=lan" -x
```

If this fails, check that the Samba DC container is running and the LDAP port (389) is exposed.

---

## Terraform Issues

### Provider Authentication Failure

**Symptom:** Terraform fails with "401 Unauthorized" or "authentication failed" errors.

**Cause:** Invalid Proxmox API credentials or the API token has expired.

**Solution:**

1. Verify the API URL and credentials in `terraform/terraform.tfvars`
2. Test the Proxmox API directly:
   ```bash
   curl -k https://<proxmox-ip>:8006/api2/json/version
   ```
3. Regenerate the API token in Proxmox if needed

### Resource Already Exists

**Symptom:** Terraform fails because a VM or LXC with the target ID already exists.

**Cause:** A previous deployment was not fully cleaned up, or the resource was created manually.

**Solution:**

1. Remove the conflicting resource in Proxmox, or
2. Import it into Terraform state:
   ```bash
   docker compose run terraform import <resource_address> <resource_id>
   ```
3. Or use emergency purge (setup.sh menu option 14) to clean up

### Timeout During Provisioning

**Symptom:** Terraform times out waiting for a VM or LXC to become ready.

**Cause:** Cloud-init is slow, the VM does not have network access, or the Proxmox host is under heavy load.

**Solution:**

1. Check the VM console in Proxmox for cloud-init progress
2. Verify network connectivity from the VM
3. Increase the timeout in the Terraform module if needed

---

## Packer Issues

### Build Fails to Connect

**Symptom:** Packer cannot SSH into the VM during the build process.

**Cause:** SSH credentials are wrong, the base template is not available, or the VM did not start properly.

**Solution:**

1. Verify the base template (VM ID 9999) exists in Proxmox
2. Check that SSH credentials in `packer/packer.auto.pkrvars.hcl` are correct
3. Look at the VM console in Proxmox during the build to see if it is booting

### Template Already Exists

**Symptom:** Packer fails because template VM ID 9001 or 9002 already exists.

**Cause:** A previous Packer build created the template and it was not removed.

**Solution:**

Delete the existing template in Proxmox before rebuilding:

```bash
ssh root@<proxmox-ip> "qm destroy 9001 --purge"
# or
ssh root@<proxmox-ip> "qm destroy 9002 --purge"
```

---

## SSH Connectivity Issues

### Cannot SSH into VMs/LXCs

**Symptom:** SSH connection refused or times out when connecting to lab VMs.

**Cause:** The SSH key is not deployed, the VM is not running, or a firewall is blocking access.

**Solution:**

1. Verify the VM is running in Proxmox
2. Check that you are using the correct SSH key:
   ```bash
   ssh -i crypto/lab-deploy user@<vm-ip>
   ```
3. Verify network connectivity:
   ```bash
   ping <vm-ip>
   ```
4. If using `sshRun` or `sshScript` helpers, verify `lib/util.sh` is sourced correctly

### Host Key Verification Failed

**Symptom:** SSH refuses to connect with "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"

**Cause:** The VM was rebuilt and has a new host key, but the old key is cached in `~/.ssh/known_hosts`.

**Solution:**

```bash
# Remove the old host key
ssh-keygen -R <vm-ip>
```
