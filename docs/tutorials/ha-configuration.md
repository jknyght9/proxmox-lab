# High Availability Configuration

This tutorial covers enabling keepalived VRRP high availability for DNS and Traefik. HA provides a Virtual IP (VIP) that floats between nodes, so a single node failure does not interrupt service.

## Prerequisites

- 3-node Proxmox cluster (HA with a single node provides no benefit)
- Core lab stack deployed (option 1 completed)
- Available IP addresses in your network for VIPs (outside DHCP range)

## Planning Your VIPs

Choose two IPs that are:
- In your lab network CIDR
- Outside your router's DHCP range
- Not in use by any other device

Choose two VRRP router IDs that are:
- Between 1 and 255
- Unique — not used by other VRRP/HSRP devices on your network (routers often use low numbers)

Example plan:
- DNS VIP: `192.168.1.3/24`, VRRP ID `51`
- Traefik VIP: `192.168.1.100/24`, VRRP ID `53`

## Configure bootstrap.yml

Add the HA settings to `bootstrap.yml`:

```yaml
ha_dns_enabled: true
ha_dns_vip: "192.168.1.3/24"         # Choose an unused IP
ha_dns_vrrp_router_id: 51             # Choose an unused VRRP ID (1-255)
ha_dns_vrrp_password: "pihole1"       # Max 8 characters

ha_traefik_enabled: true
ha_traefik_vip: "192.168.1.100/24"   # Choose an unused IP
ha_traefik_vrrp_router_id: 53
ha_traefik_vrrp_password: "trafk1"   # Max 8 characters
```

## Apply HA Configuration

From the setup menu, select option 2:

```bash
./setup.sh
# 2) Enable HA (keepalived VIPs)
```

This reads the HA settings from `bootstrap.yml` and:
1. Updates `terraform/terraform.tfvars` with the HA variables
2. Applies Layer 1 Terraform (configures keepalived on VMs and LXCs)
3. Updates `terraform/services/terraform.tfvars` with the VIP addresses
4. Applies Layer 2 Terraform (updates DNS records to point to VIPs)

!!! info "Bootstrap.yml change detection"
    The setup menu detects changes in `bootstrap.yml` on startup. If HA settings are detected but not yet applied, the menu prompts you to apply them with option `*`.

## Reconfiguring Client DNS

After enabling DNS HA, update your DNS server setting to use the VIP instead of a specific Pi-hole node IP. This ensures DNS continues to work even if one node fails.

**Router DHCP settings (recommended):** Change the DNS server to the DNS VIP.

**macOS:**
```bash
networksetup -setdnsservers Wi-Fi 192.168.1.3
```

**Linux:**
```bash
echo "nameserver 192.168.1.3" | sudo tee /etc/resolv.conf
```

## Verification

### DNS HA

```bash
# Verify VIP is bound on the master node
ssh labadmin@dns-01 "ip addr show eth0 | grep 192.168.1.3"

# Check keepalived status
ssh labadmin@dns-01 "systemctl status keepalived"

# Test DNS resolution through the VIP
dig @192.168.1.3 google.com

# Test failover: stop Pi-hole on master
ssh labadmin@dns-01 "sudo systemctl stop pihole-FTL"

# VIP should move to dns-02 within a few seconds
ssh labadmin@dns-02 "ip addr show eth0 | grep 192.168.1.3"

# DNS still resolves
dig @192.168.1.3 google.com

# Restore Pi-hole on dns-01
ssh labadmin@dns-01 "sudo systemctl start pihole-FTL"
# VIP moves back to dns-01 (preemptive mode)
```

### Traefik HA

```bash
# Verify VIP is bound on nomad01
ssh labadmin@nomad01 "ip addr show eth0 | grep 192.168.1.100"

# Check keepalived status on all Nomad nodes
for node in nomad01 nomad02 nomad03; do
  echo "=== $node ==="
  ssh labadmin@$node "systemctl status keepalived | grep -E 'Active|State'"
done

# Test Traefik through the VIP
curl -sk https://192.168.1.100/ -o /dev/null -w "%{http_code}\n"

# Test failover: stop Nomad job on master
ssh labadmin@nomad01 "nomad job stop traefik"

# VIP moves to nomad02
ssh labadmin@nomad02 "ip addr show eth0 | grep 192.168.1.100"

# Traefik still responds
curl -sk https://192.168.1.100/ -o /dev/null -w "%{http_code}\n"

# Restart Traefik
./setup.sh --dev  # d9) Deploy Traefik only
```

## Troubleshooting

### VIP not bound on any node

Check keepalived is running and the VRRP auth is correct:

```bash
# Check logs on all nodes
ssh labadmin@dns-01 "journalctl -u keepalived -n 50"
ssh labadmin@dns-02 "journalctl -u keepalived -n 50"
```

Common causes:
- VRRP password mismatch between nodes (must match exactly, max 8 chars)
- VRRP router ID conflict with another device on the network
- firewall blocking VRRP multicast (protocol 112)

### VIP on wrong node

Check priorities. nomad01 should be priority 101, nomad02 = 100, nomad03 = 99:

```bash
ssh labadmin@nomad01 "cat /etc/keepalived/keepalived.conf | grep priority"
```

If priorities are wrong, re-apply Layer 1 Terraform.

### Split-brain (VIP on multiple nodes)

Check network connectivity between nodes. Keepalived uses VRRP multicast (224.0.0.18). If nodes cannot communicate, each thinks it is the master.

```bash
# Test multicast reachability
ssh labadmin@nomad01 "ping -c 3 nomad02"
```

### VRRP authentication failing

The VRRP password is limited to 8 characters. If your password is longer, keepalived silently truncates it, which may cause mismatches between nodes.

Verify all nodes use exactly the same password (check `keepalived.conf` on each node).
