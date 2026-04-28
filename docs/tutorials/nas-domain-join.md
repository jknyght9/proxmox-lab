# NAS Domain Join

This tutorial explains how to join TrueNAS SCALE and Synology DSM to the Samba AD domain using the automated Terraform integration.

## Overview

Domain joining is handled automatically by `terraform/services/nas-domain-join.tf`. When Samba AD is deployed and NAS servers are configured in `bootstrap.yml`, Terraform:

1. Stores NAS credentials in Vault
2. SSHes into nomad01 and runs the join logic via REST API
3. Configures NAS DNS to point to Pi-hole (required for AD SRV record resolution)
4. Joins the NAS to the AD domain using the `domain-join-svc` service account
5. Polls for join completion

The join is **idempotent**: if the NAS is already joined to the correct domain, it is skipped.

## Prerequisites

- Samba AD deployed (option 4)
- NAS accessible from nomad01 on the network
- For TrueNAS: API key generated in the TrueNAS UI
- For Synology: DSM admin credentials

## Configuration

Add NAS servers to `bootstrap.yml`:

```yaml
nas_servers:
  - name: "truenas-01"
    type: "truenas"
    address: "192.168.1.50"         # Management IP or FQDN
    api_key: "abc123..."             # TrueNAS API key

  - name: "synology-01"
    type: "synology"
    address: "192.168.1.51"
    admin_user: "admin"             # DSM admin username
    admin_password: "dsm-password"  # DSM admin password
```

## TrueNAS SCALE: Generating an API Key

1. Log in to TrueNAS SCALE web UI
2. Navigate to **System** > **API Keys**
3. Click **Add**
4. Set a descriptive name (e.g., "proxmox-lab")
5. Copy the generated key into `bootstrap.yml`

The API key is stored in Vault at `secret/nas/truenas-01` after the first apply.

## Synology DSM: Preparation

The Synology DSM admin credentials are used for the initial API authentication only. The actual domain join uses the `domain-join-svc` service account created by Terraform.

Ensure:
- DSM web UI is accessible on port 5001 (HTTPS)
- The admin account has sufficient permissions (DSM Administrator)

## Applying the Configuration

After updating `bootstrap.yml`:

1. Re-run option 1 to regenerate tfvars and apply, or:
2. Re-apply Layer 2 Terraform if bootstrap has already run:

```bash
./setup.sh --dev
# d5) Deploy services
```

Or targeted:
```bash
docker compose run terraform-services apply -auto-approve \
  -target=null_resource.nas_domain_join
```

## Verifying the Domain Join

### TrueNAS

1. Log in to TrueNAS UI
2. Navigate to **Credentials** > **Directory Services**
3. Verify: Active Directory is shown as **Enabled** with the correct domain

Or via API:
```bash
curl -sk -H "Authorization: Bearer <api-key>" \
  "https://<truenas-ip>/api/v2.0/directoryservices" | jq .
```

### Synology

1. Log in to DSM
2. Navigate to **Control Panel** > **Domain/LDAP**
3. Verify: Domain is shown as joined

## Post-Join Configuration

### Setting DNS on the NAS

The Terraform join logic sets the NAS DNS to the Pi-hole IP automatically. Verify this after joining:

**TrueNAS:**
```bash
curl -sk -H "Authorization: Bearer <api-key>" \
  "https://<truenas-ip>/api/v2.0/network/configuration" | jq '.nameserver1'
```

**Synology:** Control Panel > Network > General > DNS Server

### Configuring User Home Directories

After domain join, configure where user home directories are created on the NAS:

**TrueNAS SCALE:**
1. Storage > Create Dataset: `tank/homes`
2. Sharing > Windows Shares > Add share pointing to the dataset
3. Credentials > Directory Services > AD: set Home Directory to the share

**Synology DSM:**
1. Control Panel > User and Group > Advanced
2. Enable user home service, set home path to a shared folder

### Configuring Profile Share (Roaming Profiles)

For roaming Windows profiles, configure in `bootstrap.yml`:

```yaml
profile_server: "truenas.mylab.lan"
profile_share: "profiles"
profile_drive_letter: "P"
```

This creates a group policy object (via `samba-ad-profiles.tf`) that maps the profile share on domain login.

## Troubleshooting

### TrueNAS: Cannot reach API

```bash
curl -sk -H "Authorization: Bearer <api-key>" \
  "https://<truenas-ip>/api/v2.0/system/info"
```

If this fails: verify the TrueNAS IP, that HTTPS is enabled, and the API key is correct.

### Domain join fails: DNS resolution

The NAS must be able to resolve Kerberos SRV records for the AD domain. These are served by Pi-hole, which forwards `<ad-realm>` queries to the Samba DC.

Test from nomad01:
```bash
dig @<dns-01-ip> _ldap._tcp.<ad-realm-lowercase> SRV
```

If this fails, check that Pi-hole has the AD DNS forwarding rule:
```bash
ssh labadmin@dns-01 "cat /etc/pihole/pihole.toml | grep -A5 ad_realm"
```

### Synology: Login failed

Verify the admin username and password match the DSM account. The join uses port 5001 (HTTPS). If DSM uses a different port, update `admin_password` accordingly.

### Re-joining after Samba AD reset

If Samba AD data was wiped and redeployed (new domain), the NAS join state must also be reset:

**TrueNAS:**
1. UI: Credentials > Directory Services > Leave Domain, then re-join
2. Or remove Terraform state and re-apply:
   ```bash
   docker compose run terraform-services state rm null_resource.nas_domain_join[\"truenas-01\"]
   docker compose run terraform-services apply -auto-approve
   ```

**Synology:**
1. Control Panel > Domain/LDAP > Leave Domain
2. Remove Terraform state and re-apply as above
