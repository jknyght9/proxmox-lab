# Error Reference

This page catalogs common error messages encountered in Proxmox Lab, along with their causes and solutions. Errors are organized by the tool or service that produces them.

---

## Terraform Errors

### `Error: 401 Unauthorized`

```
Error: error creating virtual machine: 401 Unauthorized
```

**Cause:** The Proxmox API token or credentials are invalid or expired.

**Solution:**

1. Check `terraform/terraform.tfvars` for correct `proxmox_api_url`, token ID, and secret
2. Verify the token in Proxmox UI under **Datacenter > Permissions > API Tokens**
3. Test API access: `curl -k https://<proxmox-ip>:8006/api2/json/version`

---

### `Error: 500 unable to create VM <id> - already exists`

```
Error: error creating virtual machine: 500 unable to create VM 905 - VM 905 already exists
```

**Cause:** A VM or LXC with the target VMID exists from a previous deployment that was not fully destroyed.

**Solution:**

- Destroy the existing VM: `ssh root@<proxmox-ip> "qm destroy 905 --purge"`
- Or use setup.sh menu option 14 (Emergency Purge)
- Or import into Terraform: `docker compose run terraform import <resource> <id>`

---

### `Error: timeout - lastass_error: dial tcp <ip>:22: connect: connection refused`

```
Error: timeout - last error: dial tcp 192.168.1.50:22: connect: connection refused
```

**Cause:** Terraform timed out waiting for SSH access to a newly created VM. The VM is still booting, cloud-init is running, or SSH is not configured.

**Solution:**

1. Check the VM console in Proxmox for boot progress
2. Verify cloud-init completed: look for `Cloud-init v. xx.x finished` in the console
3. Check network: ensure the VM has an IP address on the correct network
4. Increase the provisioner timeout in the Terraform module if the VM is slow

---

### `Error: error waiting for VM to stop: timeout`

```
Error: error waiting for VM to stop: timeout while waiting for state to become 'stopped'
```

**Cause:** Terraform is trying to stop a VM (during destroy or update) but the VM is not shutting down gracefully.

**Solution:**

1. Stop the VM manually in Proxmox
2. Retry the Terraform operation
3. If the VM is stuck, force stop it: `ssh root@<proxmox-ip> "qm stop 905 --timeout 0"`

---

### `Error: Plugin did not respond`

```
Error: Plugin did not respond
  The plugin encountered an error, and failed to respond to the plugin.(*GRPCProvider).ReadResource call
```

**Cause:** The Terraform provider crashed, often due to API rate limiting or an incompatible provider version.

**Solution:**

1. Run `docker compose run terraform init -upgrade` to update providers
2. Retry the operation
3. If persistent, check the provider version in `terraform/.terraform.lock.hcl`

---

### `Error: Could not load plugin`

```
Error: Could not load plugin
  registry.terraform.io/bpg/proxmox: could not query provider registry
```

**Cause:** No internet access from the Docker container, or the provider registry is temporarily unavailable.

**Solution:**

1. Check internet connectivity from the container
2. Retry `docker compose run terraform init`
3. If behind a proxy, configure Docker proxy settings

---

## Packer Errors

### `Error: Failed to connect to SSH`

```
Error waiting for SSH: handshake failed: ssh: unable to authenticate
```

**Cause:** Packer cannot SSH into the VM being built. The SSH credentials are wrong or the VM did not boot.

**Solution:**

1. Verify SSH username and password in `packer/packer.auto.pkrvars.hcl`
2. Check that the base template (VMID 9999) exists and boots correctly
3. Watch the VM console in Proxmox during the build

---

### `Error: 500 unable to create VM <id> - already exists`

```
Error: error creating VM: 500 unable to create VM 9001 - already exists
```

**Cause:** The template VM from a previous Packer build still exists.

**Solution:**

```bash
ssh root@<proxmox-ip> "qm destroy 9001 --purge"
# Then retry:
docker compose run packer build build_docker.pkr.hcl
```

---

### `Error: Error getting ISO path`

```
Error: error getting ISO path: ISO file not found
```

**Cause:** The ISO specified in the Packer configuration does not exist in the Proxmox storage.

**Solution:**

1. Verify the ISO is uploaded to Proxmox storage
2. Check the ISO path in the Packer source configuration
3. Upload the ISO via the Proxmox UI under the target storage

---

## Nomad Errors

### `Allocation "xyz" status "failed"`

```
Allocation "abc123" status "failed" (0/1 tasks running)
```

**Cause:** The task within the allocation failed to start or crashed.

**Solution:**

1. Check the allocation logs:
   ```bash
   docker compose run --rm nomad alloc logs <alloc-id>
   docker compose run --rm nomad alloc logs <alloc-id> -stderr
   ```
2. Check the allocation status for events:
   ```bash
   docker compose run --rm nomad alloc status <alloc-id>
   ```
3. Common sub-errors:
   - **Docker image pull failure**: check internet access on the Nomad node
   - **Port conflict**: another allocation or process is using the port
   - **Resource exhaustion**: the node does not have enough CPU/memory

---

### `No nodes were eligible for evaluation`

```
Constraint "${attr.unique.hostname} = nomad01" filtered 2 of 3 nodes
  * Constraint "${attr.unique.hostname} = nomad01": 2 nodes excluded by filter
```

**Cause:** The job has a constraint that can only be satisfied by a specific node (e.g., `nomad01`), and that node is not eligible.

**Solution:**

1. Check node status: `docker compose run --rm nomad node status`
2. Verify nomad01 is `ready` and `eligible`
3. If nomad01 is draining, disable drain: `docker compose run --rm nomad node drain -disable <node-id>`

---

### `Vault token not found`

```
Template error: vault: vault.read: error reading secret/data/authentik: Vault token not found
```

**Cause:** The Nomad job requires Vault secrets but the Workload Identity Federation (WIF) is not configured, or Vault is sealed.

**Solution:**

1. Check that Vault is unsealed:
   ```bash
   curl -s http://<nomad01-ip>:8200/v1/sys/health | jq .
   ```
2. Verify the JWT auth backend is configured in Vault at `jwt-nomad`
3. Check that the job's `vault { role = "<role>" }` stanza matches a configured Vault role
4. Re-run the Vault WIF setup if needed

---

### `Failed to pull image`

```
Failed to pull `docker.io/library/xxx:latest`: Error response from daemon: pull access denied
```

**Cause:** The Docker image cannot be pulled. Network issue, image does not exist, or Docker Hub rate limit reached.

**Solution:**

1. Check internet connectivity on the Nomad node
2. Verify the image name and tag in the job definition
3. Try pulling the image manually on the node:
   ```bash
   ssh user@<nomad01-ip> "docker pull <image>:<tag>"
   ```

---

## Vault Errors

### `server is not yet initialized`

```
Error making API request: server is not yet initialized
```

**Cause:** Vault has been deployed but not initialized. This is expected on first deployment.

**Solution:**

The setup.sh script handles initialization automatically. If you need to initialize manually:

```bash
curl -X PUT http://<nomad01-ip>:8200/v1/sys/init \
  -d '{"secret_shares": 1, "secret_threshold": 1}'
```

Save the returned unseal key and root token to `crypto/vault-credentials.json`.

---

### `Vault is sealed`

```
Error making API request: Vault is sealed
```

**Cause:** Vault has been restarted and needs to be unsealed.

**Solution:** See [Backup & Recovery - Vault Unseal](../operations/backup-recovery.md#vault-unseal-after-restart).

---

### `permission denied`

```
Error making API request: permission denied
```

**Cause:** The token being used does not have the necessary policy permissions for the requested operation.

**Solution:**

1. Verify you are using the root token for administrative operations
2. For WIF-authenticated jobs, check the Vault policy allows the requested path
3. Review policies in `nomad/vault-policies/`

---

## GlusterFS Errors

### `Transport endpoint is not connected`

```
ls: cannot access '/srv/gluster/nomad-data': Transport endpoint is not connected
```

**Cause:** The GlusterFS mount has been disconnected, usually after a node reboot or network interruption.

**Solution:**

```bash
ssh user@<nomad-node> "sudo umount /srv/gluster/nomad-data; sudo mount -t glusterfs localhost:/nomad-data /srv/gluster/nomad-data"
```

---

### `Split-brain detected`

```
Volume nomad-data: split-brain detected on file <path>
```

**Cause:** Conflicting writes occurred while the cluster was partitioned.

**Solution:**

```bash
# Check which files are in split-brain
ssh user@<nomad01-ip> "sudo gluster volume heal nomad-data info split-brain"

# Resolve by choosing a source brick
ssh user@<nomad01-ip> "sudo gluster volume heal nomad-data split-brain source-brick <brick> <file>"
```

---

## SSH Errors

### `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
```

**Cause:** The VM was rebuilt and has a new SSH host key.

**Solution:**

```bash
ssh-keygen -R <ip-address>
```

---

### `Permission denied (publickey)`

```
user@192.168.1.50: Permission denied (publickey).
```

**Cause:** The SSH key is not being used or is not authorized on the target host.

**Solution:**

1. Specify the correct key: `ssh -i crypto/lab-deploy user@<ip>`
2. Verify the public key is in the VM's `~/.ssh/authorized_keys`
3. Check that `crypto/lab-deploy` has correct permissions: `chmod 600 crypto/lab-deploy`
