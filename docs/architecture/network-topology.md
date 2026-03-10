# Network Topology

This page details the network architecture of Proxmox Lab.

## Dual Network Design

Proxmox Lab uses two separate networks:

1. **External Network (vmbr0)** - Your existing LAN
2. **Internal Network (labnet)** - Isolated SDN for lab testing

```mermaid
graph TB
    subgraph internet["Internet"]
        WAN((WAN))
    end

    subgraph external["External Network (vmbr0)"]
        ROUTER[Router/Gateway<br/>e.g., 10.1.50.1]
        VMBR0[Network Bridge<br/>vmbr0]

        subgraph ext_services["External Services"]
            PH_EXT[pihole-external<br/>10.1.50.3]
            STEPCA[step-ca<br/>10.1.50.4]
            D1[docker01]
            D2[docker02]
            D3[docker03]
            KASM_EXT[kasm01]
        end
    end

    subgraph internal["Internal Network (labnet SDN)"]
        SDN_GW[SDN Gateway<br/>172.16.0.1]

        subgraph int_services["Lab Services"]
            PH_INT[pihole-internal<br/>172.16.0.3]
            LAB_VMS[Lab VMs<br/>DHCP: 172.16.0.100+]
        end
    end

    WAN --> ROUTER
    ROUTER --> VMBR0
    VMBR0 --> PH_EXT & STEPCA & D1 & D2 & D3 & KASM_EXT
    VMBR0 --> SDN_GW
    SDN_GW --> PH_INT
    PH_INT --> LAB_VMS
```

## External Network (vmbr0)

The external network connects to your physical LAN.

### Configuration

| Setting | Example Value | Description |
|---------|---------------|-------------|
| Bridge Name | `vmbr0` | Proxmox network bridge |
| Network Range | `10.1.50.0/24` | Your LAN subnet |
| Gateway | `10.1.50.1` | Your router IP |

### IP Assignments

| Service | IP Address | Assignment Type |
|---------|------------|-----------------|
| Router/Gateway | 10.1.50.1 | Static (your router) |
| Proxmox Host | 10.1.50.2 | Static |
| pihole-external | 10.1.50.3 | Static (configured) |
| step-ca | 10.1.50.4 | Static (configured) |
| docker01 | Dynamic | DHCP |
| docker02 | Dynamic | DHCP |
| docker03 | Dynamic | DHCP |
| kasm01 | Dynamic | DHCP |

!!! tip "Static IP Reservation"
    For Docker and Kasm VMs, you can set DHCP reservations in your router
    or configure static IPs in the Terraform variables.

## Internal Network (labnet)

The internal network is a Software Defined Network (SDN) for isolated testing.

### Configuration

| Setting | Value | Description |
|---------|-------|-------------|
| Network Name | `labnet` | SDN zone name |
| Network Range | `172.16.0.0/24` | Private IP range |
| Gateway | `172.16.0.1` | Proxmox SDN gateway |
| DNS Server | `172.16.0.3` | pihole-internal |
| DHCP Range | `172.16.0.100-200` | Dynamic assignments |

### IP Assignments

| Service | IP Address | Purpose |
|---------|------------|---------|
| SDN Gateway | 172.16.0.1 | Proxmox routing |
| pihole-internal | 172.16.0.3 | DNS + DHCP server |
| Lab VMs | 172.16.0.100+ | DHCP assigned |

## DNS Resolution Architecture

### External DNS Flow

```mermaid
sequenceDiagram
    participant Client as Client Machine
    participant Pihole as pihole-external
    participant Unbound as Unbound
    participant DNSCrypt as dnscrypt-proxy
    participant Internet as DNS Servers

    Client->>Pihole: DNS Query (port 53)

    alt Local Record (*.mylab.lan)
        Pihole-->>Client: Return configured IP
    else Blocked Domain (ads, tracking)
        Pihole-->>Client: Return 0.0.0.0
    else External Domain
        Pihole->>Unbound: Forward query (port 5335)
        Unbound->>DNSCrypt: Recursive lookup
        DNSCrypt->>Internet: DNS-over-HTTPS
        Internet-->>DNSCrypt: Response
        DNSCrypt-->>Unbound: Response
        Unbound-->>Pihole: Cached response
        Pihole-->>Client: Response
    end
```

### Internal DNS Flow

```mermaid
sequenceDiagram
    participant LabVM as Lab VM
    participant PiholeInt as pihole-internal
    participant PiholeExt as pihole-external

    LabVM->>PiholeInt: DNS Query

    alt Lab Record
        PiholeInt-->>LabVM: Return lab IP
    else External Query
        PiholeInt->>PiholeExt: Forward to external
        PiholeExt-->>PiholeInt: Response
        PiholeInt-->>LabVM: Response
    end
```

### DNS Server Stack

Each Pihole container includes:

| Component | Port | Purpose |
|-----------|------|---------|
| **Pihole** | 53 | DNS server + ad blocking |
| **Unbound** | 5335 | Recursive DNS resolver |
| **dnscrypt-proxy** | 5053 | DNS-over-HTTPS encryption |

## Port Reference

### Services Listening

| Service | Port(s) | Protocol | Purpose |
|---------|---------|----------|---------|
| Proxmox Web UI | 8006 | HTTPS | Management interface |
| SSH | 22 | TCP | Remote access |
| Pihole Admin | 80 | HTTP | Web interface |
| Pihole DNS | 53 | UDP/TCP | DNS queries |
| Step-CA ACME | 443 | HTTPS | Certificate requests |
| Kasm | 443 | HTTPS | Web interface |
| Docker Swarm | 2377 | TCP | Cluster management |
| Docker Swarm | 7946 | TCP/UDP | Node communication |
| Docker Overlay | 4789 | UDP | Overlay network |

### Firewall Rules (if applicable)

If you have a firewall between segments:

| From | To | Port | Purpose |
|------|-----|------|---------|
| Workstation | Proxmox | 8006/tcp | Web UI access |
| Workstation | Proxmox | 22/tcp | SSH access |
| All services | pihole-external | 53/udp | DNS resolution |
| All services | step-ca | 443/tcp | Certificate requests |
| Docker nodes | Docker nodes | 2377,7946/tcp | Swarm management |
| Docker nodes | Docker nodes | 4789/udp | Overlay network |

## Routing Between Networks

### External to Internal

By default, external network clients **cannot** directly access labnet services.

To access labnet:

1. **Through a dual-homed VM** - Kasm is connected to both networks
2. **Via Proxmox routing** - Configure routes on your router
3. **Through a VPN** - Set up WireGuard on a labnet VM

### Internal to External

Labnet VMs can access:

- External DNS (via pihole-internal forwarding to pihole-external)
- Internet (via Proxmox NAT through vmbr0)
- Step-CA for certificates

## Network Diagram for Documentation

Use this simplified diagram for presentations:

```mermaid
graph LR
    subgraph "Your Network"
        YOU[Your Devices]
    end

    subgraph "Proxmox Lab"
        subgraph "External (vmbr0)"
            DNS[Pihole DNS]
            CA[Step-CA]
            SWARM[Docker Swarm]
        end

        subgraph "Lab (SDN)"
            LAB[Lab Environment]
        end
    end

    YOU --> DNS
    DNS --> CA
    SWARM --> CA
    LAB -.-> DNS
```

## Tailscale Integration

Proxmox Lab supports running Tailscale on Proxmox cluster nodes for remote access while maintaining local DNS resolution.

### Automatic DNS Coexistence

When you update DNS records (setup.sh option 10 "Build DNS records"), the setup script automatically:

1. Detects if Tailscale is installed on any Proxmox cluster nodes
2. Runs `tailscale set --accept-dns=false` to disable MagicDNS management
3. Prevents Tailscale from overwriting `/etc/resolv.conf` with its DNS server (100.100.100.100)
4. Allows the system to use your manually configured Pi-hole DNS servers

### Tailscale Networking

After disabling DNS management:

- Tailscale networking remains fully functional for remote access
- You can still connect to nodes via Tailscale IPs (e.g., `100.x.x.x`)
- VPN tunnel and peer-to-peer connections continue working normally
- Only MagicDNS name resolution (e.g., `node.tailnet.ts.net`) is disabled on cluster nodes

### Workarounds for MagicDNS

If you need to resolve Tailscale MagicDNS names from your Proxmox nodes:

1. **Use Tailscale IPs directly** - Access nodes via their `100.x.x.x` addresses
2. **Add local DNS records** - Configure Pi-hole to resolve your Tailscale hostnames:
   ```bash
   # On dns-01, add Tailscale hosts to Pi-hole
   pihole-FTL --config dns.hosts '["100.x.x.x myhost myhost.tail-scale.ts.net"]'
   ```
3. **Use /etc/hosts** - Add static entries to individual nodes if needed

### Why Disable Tailscale DNS?

Tailscale's MagicDNS feature automatically configures DNS servers on connected devices. For Proxmox Lab:

- Local services must resolve via Pi-hole for proper DNS records
- Pi-hole provides ad-blocking and custom local domain resolution
- Proxmox nodes need consistent DNS configuration for cluster operations
- Preventing DNS conflicts ensures reliable service discovery

!!! tip "Best Practice"
    Run the DNS update (setup.sh option 10) after installing or updating Tailscale on Proxmox nodes to ensure proper DNS configuration.

## Next Steps

- [:octicons-arrow-right-24: Service Relationships](service-relationships.md) - How services depend on each other
- [:octicons-arrow-right-24: Certificate Chain](certificate-chain.md) - TLS certificate architecture
- [:octicons-arrow-right-24: DNS Management](../operations/dns-management.md) - Managing DNS records
