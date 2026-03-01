# DNS Management

This page covers day-to-day DNS management in Proxmox Lab, including the Pi-hole admin interface, local DNS record management, Gravity Sync replication, and Samba AD DNS forwarding.

---

## Architecture Overview

The DNS resolution chain in Proxmox Lab is:

```
Client --> Pi-hole (ad blocking + local DNS) --> Unbound (DNS-over-TLS) --> Cloudflare / Quad9
```

### Pi-hole Instances

**Main DNS cluster** (one per Proxmox cluster node):

| Hostname | VMID | Network |
|----------|------|---------|
| dns-01 | 910 | External (vmbr0) |
| dns-02 | 911 | External (vmbr0) |
| dns-03 | 912 | External (vmbr0) |

**Labnet DNS cluster** (internal SDN, max 2 nodes):

| Hostname | VMID | Network |
|----------|------|---------|
| labnet-dns-01 | 920 | Labnet (SDN) |
| labnet-dns-02 | 921 | Labnet (SDN) |

---

## Pi-hole v6 Admin Interface

Access the Pi-hole web admin at `http://<dns-ip>/admin`.

- **Password**: the `pihole_admin_password` value from `terraform/terraform.tfvars`
- **Dashboard**: shows query statistics, top blocked domains, and upstream DNS status
- **Local DNS**: manage local DNS records through the web interface under **Local DNS > DNS Records**

!!! info "Pi-hole v6"
    Proxmox Lab uses Pi-hole v6, which uses a TOML configuration file (`/etc/pihole/pihole.toml`) and the FTL (Faster Than Light) DNS engine. This differs significantly from Pi-hole v5 which used `setupVars.conf` and `dnsmasq`.

---

## Managing Local DNS Records

### Configuration File

Pi-hole v6 stores local DNS records in the `dns.hosts` array within `/etc/pihole/pihole.toml`:

```toml
[dns]
  hosts = [
    "192.168.1.50 vault.mylab.lan",
    "192.168.1.50 auth.mylab.lan",
    "192.168.1.50 traefik.mylab.lan",
    "192.168.1.10 ca.mylab.lan"
  ]
```

### Adding Records via setup.sh

The easiest way to manage DNS records is through the setup menu:

```bash
./setup.sh
# Select option 10: Build DNS records
```

This runs the `updateDNSRecords` function which:

1. Reads `hosts.json` to discover all deployed hosts
2. Adds service DNS entries (vault, auth, traefik) pointing to nomad01
3. Adds infrastructure DNS entries for all Pi-hole, Nomad, Step-CA, and Kasm nodes
4. Pushes the updated configuration to all Pi-hole instances

### Adding Records Manually

To add a DNS record directly on a Pi-hole instance:

```bash
# SSH into the Pi-hole LXC
ssh root@<dns-ip>

# View current DNS hosts
pihole-FTL --config dns.hosts

# Add a new record (replaces entire array -- include all existing entries)
pihole-FTL --config dns.hosts '["192.168.1.50 vault.mylab.lan", "192.168.1.50 auth.mylab.lan", "192.168.1.60 newservice.mylab.lan"]'
```

!!! warning "Array replacement"
    The `pihole-FTL --config dns.hosts` command replaces the entire `dns.hosts` array. Always include all existing records when adding new ones. Read the current value first with `pihole-FTL --config dns.hosts` before making changes.

### Removing Records

To remove a DNS record, rewrite the `dns.hosts` array without the entry you want to remove:

```bash
# Read current records
pihole-FTL --config dns.hosts

# Write back the array without the unwanted record
pihole-FTL --config dns.hosts '["192.168.1.50 vault.mylab.lan", "192.168.1.50 auth.mylab.lan"]'
```

---

## Gravity Sync and Replication

Pi-hole instances replicate their configurations using **nebula-sync**, which runs every 5 minutes.

### How It Works

1. The **primary** Pi-hole instance (dns-01) serves as the source of truth
2. **nebula-sync** replicates configuration from the primary to secondary nodes
3. Replication runs on a 5-minute interval
4. Changes made to secondary nodes will be overwritten on the next sync cycle

!!! tip "Always make changes on the primary"
    To ensure your changes persist, always add or modify DNS records on the primary Pi-hole instance (dns-01). Changes on secondary nodes will be overwritten by nebula-sync within 5 minutes.

### Verifying Sync Status

Check that all Pi-hole instances have the same DNS records:

```bash
# On dns-01 (primary)
ssh root@<dns-01-ip> "pihole-FTL --config dns.hosts"

# On dns-02 (secondary)
ssh root@<dns-02-ip> "pihole-FTL --config dns.hosts"
```

If records are out of sync, wait 5 minutes for nebula-sync to run, or make the change on the primary and let it propagate.

---

## Samba AD DNS Forwarding

When Samba Active Directory is deployed, Pi-hole is configured to forward AD realm queries to the Samba Domain Controllers.

### How It Works

Pi-hole uses conditional forwarding to route DNS queries for the AD realm (e.g., `ad.mylab.lan`) to the Samba DCs:

- **DC01** (nomad01): listens on port **5353**
- **DC02** (nomad02): listens on port **5354**

The forwarding rules are configured in `/etc/dnsmasq.d/10-ad-forward.conf` on each Pi-hole instance:

```
server=/ad.mylab.lan/192.168.1.50#5353
server=/ad.mylab.lan/192.168.1.51#5354
```

### Verifying AD DNS

Test that AD DNS resolution works through Pi-hole:

```bash
# Query an AD record through Pi-hole
dig @<dns-ip> _ldap._tcp.ad.mylab.lan SRV

# Query a DC directly
dig @<nomad01-ip> -p 5353 _ldap._tcp.ad.mylab.lan SRV
```

### Adding AD Forwarding Manually

If AD DNS forwarding is not configured, you can set it up manually on each Pi-hole:

```bash
ssh root@<dns-ip> "cat > /etc/dnsmasq.d/10-ad-forward.conf << 'EOF'
server=/ad.mylab.lan/192.168.1.50#5353
server=/ad.mylab.lan/192.168.1.51#5354
EOF
pihole restartdns"
```

---

## DNS Records for Nomad Services

The `updateDNSRecords` function in `setup.sh` creates the following service records:

| DNS Record | Target | Purpose |
|-----------|--------|---------|
| `vault.<domain>` | nomad01 IP | Vault secrets manager |
| `auth.<domain>` | nomad01 IP | Authentik identity provider |
| `traefik.<domain>` | nomad01 IP | Traefik reverse proxy |
| `ca.<domain>` | step-ca LXC IP | Certificate Authority |
| `samba-dc01.<ad_realm>` | nomad01 IP | Primary AD Domain Controller |
| `samba-dc02.<ad_realm>` | nomad02 IP | Secondary AD Domain Controller |

All Nomad services are pinned to nomad01 via job constraints, so their DNS records all point to the nomad01 IP address.

---

## Labnet DNS

The labnet DNS cluster serves the isolated SDN network. Since the SDN is not directly reachable from the host, labnet Pi-hole instances are provisioned via `pct exec`:

```bash
# Proxmox runs commands inside the LXC container
pct exec <vmid> -- <command>
```

Labnet DNS mirrors the same records as the main DNS cluster but is accessible only from within the labnet SDN.

---

## Common DNS Tasks

### Verify a Record Resolves

```bash
# Using dig
dig @<dns-ip> vault.mylab.lan

# Using nslookup
nslookup vault.mylab.lan <dns-ip>
```

### Flush Pi-hole Cache

```bash
ssh root@<dns-ip> "pihole restartdns"
```

### Check Pi-hole Service Status

```bash
ssh root@<dns-ip> "systemctl status pihole-FTL"
```

### View DNS Query Log

Access the Pi-hole admin dashboard at `http://<dns-ip>/admin` and navigate to **Query Log** for recent queries, or check the long-term database under **Long-term data**.
