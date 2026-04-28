# Kasm Workspaces

Kasm Workspaces provides browser-based remote desktops and application streaming. It is deployed as an optional Proxmox VM (VMID 930).

## Overview

| Property | Value |
|----------|-------|
| **Type** | Proxmox VM |
| **VMID** | 930 |
| **Template** | ubuntu-docker (9001) |
| **Module** | `terraform/vm-kasm/` |
| **Ports** | 443 (HTTPS web UI) |
| **Credentials** | Admin password from Vault at `secret/kasm` |

## Deployment

Select option 3 from the setup menu:

```bash
./setup.sh
# 3) Kasm Workspaces
```

Or apply directly via Layer 1 Terraform:

```bash
docker compose run terraform apply -auto-approve -var "deploy_kasm=true"
```

!!! info "Prerequisites"
    Vault and Traefik must be deployed before Kasm. The Kasm admin password is read from Vault at deploy time (`secret/kasm` -> `admin_password`).

## Accessing Kasm

After deployment, Kasm is accessible at:

```
https://<kasm-ip>  (direct, self-signed Kasm cert)
```

DNS record (`kasm.<dns-suffix>`) points directly to the Kasm VM IP, not through Traefik. Kasm handles its own TLS.

Default admin credentials:
- **URL**: `https://<kasm-ip>`
- **Username**: `admin@kasm.local`
- **Password**: From Vault: `vault kv get -field=admin_password secret/kasm`

## LDAP Authentication with Samba AD

To configure Kasm to authenticate via Samba AD LDAP, see the tutorial: [Kasm LDAP Authentication](../tutorials/kasm-ad-auth.md).

## Cloud-init Provisioning

The Kasm VM is provisioned via cloud-init (`terraform/vm-kasm/cloudinit/kasm-user-data.tmpl`). The cloud-init script:
1. Sets hostname and SSH authorized key
2. Installs Kasm Workspaces (downloads installer, runs `kasm_installer.sh`)
3. Sets the admin password

## Troubleshooting

### Kasm installer fails

The Kasm installer downloads a large package from the internet. Ensure the VM has internet access and DNS is working:

```bash
ssh labadmin@kasm01 "curl -v https://kasm.io"
```

### Admin login fails

Retrieve the password from Vault:

```bash
vault kv get -field=admin_password secret/kasm
```

If the password is incorrect (e.g., redeployed with different Vault data), reset it via Kasm's CLI:

```bash
ssh labadmin@kasm01 "sudo /opt/kasm/bin/utils/api_server_mgmt.py --reset-admin-password"
```
