# Kasm LDAP Authentication with Samba AD

This tutorial connects Kasm Workspaces to Samba AD so users can log in with
their domain credentials. The credentials pass through to VM sessions
(SSH, RDP, VNC) so users don't have to re-enter them.

## Prerequisites

- Samba AD deployed (option 4)
- Kasm deployed (option 3)
- At least one AD user created (via LAM or samba-tool)

## Architecture

```
User → Kasm login → LDAP bind (port 389) → Samba AD → credentials verified
                  → VM session (SSH/RDP/VNC) → credentials passed through
```

Kasm connects directly to Samba AD via LDAP. This is intentional — OIDC/SAML
would provide SSO but cannot pass the actual password to VM sessions.

!!! note "LDAP vs LDAPS"
    Samba AD supports both plaintext LDAP (port 389) and LDAPS (port 636).
    LDAPS uses a self-signed certificate generated during domain provisioning.
    Use `ldaps://<nomad01-ip>:636` for encrypted connections. If the LDAP
    client requires a trusted CA, import the Samba auto-generated cert or
    use `ldap://` on port 389 for simplicity on trusted networks.

## Step 1: Get Credentials from Vault

Retrieve the LDAP bind credentials:

```bash
# From your workstation (replace vault address as needed)
vault kv get -field=authentik_sync_password secret/samba-ad/service-accounts
vault kv get -field=authentik_sync_dn secret/samba-ad/service-accounts
```

Or via the API:

```bash
curl -sk -H "X-Vault-Token: <root-token>" \
  https://<nomad01-ip>:8200/v1/secret/data/samba-ad/service-accounts | \
  jq '.data.data | {authentik_sync_dn, authentik_sync_password}'
```

## Step 2: Configure LDAP in Kasm

1. Log in to the Kasm admin panel: `https://kasm.<dns-suffix>`
2. Navigate to **Access Management** > **Authentication** > **LDAP**
3. Click **Add Configuration**

Enter the following:

| Field | Value |
|-------|-------|
| Name | `Samba AD` |
| URL | `ldap://<nomad01-ip>:389` |
| Search Base | `DC=<domain>,DC=<tld>` (e.g., `DC=jdclabs,DC=lan`) |
| Search Filter | `(sAMAccountName=%(user)s)` |
| Group Search Filter | `(objectClass=group)` |
| Group Member Attribute | `member` |
| Search Subtree | enabled |
| Auto Create App User | enabled |
| Service Account DN | `CN=authentik-sync,CN=Users,DC=<domain>,DC=<tld>` |
| Service Account Password | Value from Step 1 |

4. Click **Submit**

## Step 3: Test Login

1. Log out of the Kasm admin panel
2. On the login page, enter an AD username and password
3. Verify login succeeds and the user dashboard loads
4. Launch a VM session (SSH or RDP) and verify credentials pass through

## Step 4: Configure Group Mapping (Optional)

To map AD groups to Kasm groups:

1. Navigate to **Access Management** > **Groups**
2. Select a Kasm group (e.g., "All Users")
3. Under **LDAP Groups**, add the AD group name (e.g., `Domain Users`)

## Troubleshooting

### Connection fails

Test LDAP connectivity from a Nomad node:

```bash
# Install ldap-utils if needed
sudo apt-get install -y ldap-utils

# Test bind with service account
ldapsearch -x -H ldap://<nomad01-ip>:389 \
  -D "CN=authentik-sync,CN=Users,DC=<domain>,DC=<tld>" \
  -w '<password>' \
  -b "DC=<domain>,DC=<tld>" \
  "(sAMAccountName=*)" sAMAccountName | head -20
```

### Login fails for specific users

Check if the user exists in AD:

```bash
# Find the Samba container
CID=$(docker ps --format '{{.ID}} {{.Names}}' | grep samba-ad | head -1 | awk '{print $1}')

# Look up user
docker exec $CID samba-tool user show <username>
```

### Credentials not passing through to VMs

This only works with LDAP authentication — not OIDC or SAML. Verify that:

1. Kasm is configured for LDAP (not SAML/OIDC)
2. The user logged in via the LDAP method (not local Kasm account)
3. The VM session type supports credential passthrough (SSH, RDP, VNC)
