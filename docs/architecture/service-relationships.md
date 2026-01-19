# Service Relationships

This page explains how services in Proxmox Lab depend on and interact with each other.

## Deployment Order

Services must be deployed in a specific order due to dependencies:

```mermaid
graph TD
    subgraph phase1["Phase 1: Foundation"]
        SSH[SSH Keys]
        PVE[Proxmox Config]
    end

    subgraph phase2["Phase 2: Network & Templates"]
        SDN[labnet SDN]
        TPL[VM/LXC Templates]
    end

    subgraph phase3["Phase 3: Core Services"]
        PIHOLE_EXT[pihole-external]
        STEPCA[step-ca]
    end

    subgraph phase4["Phase 4: Infrastructure"]
        PIHOLE_INT[pihole-internal]
        DOCKER[Docker Swarm]
        KASM[Kasm Workspaces]
    end

    SSH --> PVE
    PVE --> SDN
    PVE --> TPL
    SDN --> PIHOLE_INT
    TPL --> PIHOLE_EXT
    TPL --> STEPCA
    PIHOLE_EXT --> STEPCA
    TPL --> DOCKER
    TPL --> KASM
    STEPCA --> DOCKER
    STEPCA --> KASM
```

### Dependency Explanation

| Phase | Service | Depends On | Reason |
|-------|---------|------------|--------|
| 1 | SSH Keys | - | Required for all remote operations |
| 1 | Proxmox Config | SSH Keys | Needs SSH access to configure |
| 2 | SDN (labnet) | Proxmox Config | SDN is a Proxmox feature |
| 2 | Templates | Proxmox Config | Need storage and network |
| 3 | pihole-external | Templates | Cloned from LXC template |
| 3 | step-ca | pihole-external | Needs DNS resolution |
| 4 | pihole-internal | SDN | Runs on labnet |
| 4 | Docker Swarm | step-ca | Needs TLS certificates |
| 4 | Kasm | step-ca | Needs TLS certificates |

## Service Communication Matrix

### Runtime Dependencies

| Service | Talks To | Protocol | Purpose |
|---------|----------|----------|---------|
| **All Services** | pihole-external | DNS (53) | Name resolution |
| **Docker VMs** | step-ca | HTTPS (443) | Certificate requests |
| **Kasm** | step-ca | HTTPS (443) | Certificate requests |
| **Docker nodes** | Docker nodes | TCP 2377, 7946 | Swarm management |
| **Proxmox** | step-ca | HTTPS (443) | Web UI certificate |
| **pihole-internal** | pihole-external | DNS (53) | Forwarded queries |
| **Clients** | Kasm | HTTPS (443) | Web access |
| **Clients** | pihole-external | HTTP (80) | Admin interface |

### Communication Flow Diagram

```mermaid
graph LR
    subgraph clients["Client Machines"]
        BROWSER[Web Browser]
    end

    subgraph dns_layer["DNS Layer"]
        PIHOLE_EXT[pihole-external]
        PIHOLE_INT[pihole-internal]
    end

    subgraph ca_layer["Security Layer"]
        STEPCA[step-ca]
    end

    subgraph app_layer["Application Layer"]
        DOCKER[Docker Swarm]
        KASM[Kasm]
        PROXMOX[Proxmox UI]
    end

    BROWSER --> PIHOLE_EXT
    BROWSER --> KASM
    BROWSER --> PROXMOX

    PIHOLE_INT --> PIHOLE_EXT

    DOCKER --> PIHOLE_EXT
    DOCKER --> STEPCA
    KASM --> PIHOLE_EXT
    KASM --> STEPCA
    PROXMOX --> STEPCA
```

## Docker Swarm Topology

### Manager Node Relationships

All three Docker nodes are configured as Swarm managers for high availability:

```mermaid
graph TB
    subgraph swarm["Docker Swarm Cluster"]
        D1[docker01<br/>Manager - Leader]
        D2[docker02<br/>Manager - Reachable]
        D3[docker03<br/>Manager - Reachable]

        D1 <-->|Raft Consensus| D2
        D2 <-->|Raft Consensus| D3
        D3 <-->|Raft Consensus| D1
    end

    subgraph storage["Shared Storage"]
        GFS[GlusterFS Volume<br/>/gluster/volume1]
    end

    D1 --> GFS
    D2 --> GFS
    D3 --> GFS
```

### Swarm Port Usage

| Port | Protocol | Purpose |
|------|----------|---------|
| 2377 | TCP | Cluster management |
| 7946 | TCP/UDP | Node discovery and gossip |
| 4789 | UDP | Overlay network (VXLAN) |

### GlusterFS Replication

```mermaid
graph LR
    subgraph gluster["GlusterFS Replicated Volume"]
        B1[Brick 1<br/>docker01:/gluster/volume1]
        B2[Brick 2<br/>docker02:/gluster/volume1]
        B3[Brick 3<br/>docker03:/gluster/volume1]

        B1 <-->|Sync| B2
        B2 <-->|Sync| B3
        B3 <-->|Sync| B1
    end
```

Data written to any node is replicated to all three nodes.

## Pihole DNS Relationships

### External Pihole (pihole-external)

```mermaid
graph TD
    subgraph pihole_ext["pihole-external Stack"]
        PH[Pihole<br/>Port 53]
        UB[Unbound<br/>Port 5335]
        DC[dnscrypt-proxy<br/>Port 5053]
    end

    CLIENT[Client Query] --> PH
    PH -->|Recursive| UB
    UB -->|Encrypted| DC
    DC -->|DoH| INTERNET((Internet))
```

### Internal Pihole (pihole-internal)

```mermaid
graph TD
    subgraph pihole_int["pihole-internal"]
        PH_INT[Pihole<br/>DNS + DHCP]
    end

    LAB_VM[Lab VM] --> PH_INT
    PH_INT -->|Forward| PIHOLE_EXT[pihole-external]
```

## Certificate Request Flow

When a service needs a TLS certificate:

```mermaid
sequenceDiagram
    participant Service
    participant ACME as acme.sh
    participant DNS as pihole-external
    participant CA as step-ca

    Service->>ACME: Request certificate
    ACME->>DNS: Resolve ca.mylab.lan
    DNS-->>ACME: Return step-ca IP
    ACME->>CA: ACME challenge (HTTPS)
    CA->>CA: Verify domain ownership
    CA-->>ACME: Issue certificate
    ACME->>Service: Install cert + key
```

## Failure Scenarios

### Single Docker Node Failure

```mermaid
graph TB
    subgraph healthy["Healthy State"]
        H1[docker01 ✓]
        H2[docker02 ✓]
        H3[docker03 ✓]
    end

    subgraph failure["Node Failure"]
        F1[docker01 ✓]
        F2[docker02 ✗]
        F3[docker03 ✓]
    end

    healthy -->|docker02 fails| failure

    style F2 fill:#f66
```

**Impact:** Swarm continues operating. Services on failed node are rescheduled.

### Pihole-External Failure

**Impact:** All DNS resolution fails for external network.

**Mitigation:** Configure a backup DNS in your router.

### Step-CA Failure

**Impact:** New certificates cannot be issued. Existing certificates continue working.

**Mitigation:** Restore from backup. See [Backup & Recovery](../operations/backup-recovery.md).

## Health Check Endpoints

| Service | Health Check | Expected Response |
|---------|--------------|-------------------|
| step-ca | `https://ca.mylab.lan/health` | `{"status":"ok"}` |
| pihole | `http://pihole-ip/admin/api.php` | JSON response |
| Docker | `docker node ls` | Node list |

## Next Steps

- [:octicons-arrow-right-24: Certificate Chain](certificate-chain.md) - TLS certificate hierarchy
- [:octicons-arrow-right-24: Docker Swarm Operations](../operations/docker-swarm-operations.md) - Managing the cluster
- [:octicons-arrow-right-24: Troubleshooting](../troubleshooting/common-issues.md) - When things go wrong
