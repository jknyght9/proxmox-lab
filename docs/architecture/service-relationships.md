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
        TPL[Packer Templates]
    end

    subgraph phase3["Phase 3: Core Services"]
        DNS[DNS Cluster]
        STEPCA[step-ca]
    end

    subgraph phase4["Phase 4: Infrastructure"]
        NOMAD[Nomad Cluster]
        KASM[Kasm Workspaces]
    end

    subgraph phase5["Phase 5: Nomad Jobs"]
        TRAEFIK[Traefik]
        VAULT[Vault]
        AUTHENTIK[Authentik]
    end

    SSH --> PVE
    PVE --> SDN
    PVE --> TPL
    TPL --> DNS
    TPL --> STEPCA
    DNS --> STEPCA
    TPL --> NOMAD
    TPL --> KASM
    STEPCA --> NOMAD
    STEPCA --> KASM
    NOMAD --> TRAEFIK
    TRAEFIK --> VAULT
    VAULT --> AUTHENTIK
```

### Dependency Explanation

| Phase | Service | Depends On | Reason |
|-------|---------|------------|--------|
| 1 | SSH Keys | - | Required for all remote operations |
| 1 | Proxmox Config | SSH Keys | Needs SSH access to configure |
| 2 | SDN (labnet) | Proxmox Config | SDN is a Proxmox feature |
| 2 | Packer Templates | Proxmox Config | Need storage and network |
| 3 | DNS Cluster | Packer Templates | Deploy from templates |
| 3 | step-ca | DNS Cluster | Needs DNS resolution |
| 4 | Nomad Cluster | step-ca, Templates | Needs TLS certificates |
| 4 | Kasm | step-ca, Templates | Needs TLS certificates |
| 5 | Traefik | Nomad Cluster | Runs as Nomad job |
| 5 | Vault | Traefik | Needs ingress routing |
| 5 | Authentik | Vault | Fetches secrets from Vault |

## Service Communication Matrix

### Runtime Dependencies

| Service | Talks To | Protocol | Purpose |
|---------|----------|----------|---------|
| **All Services** | DNS Cluster | DNS (53) | Name resolution |
| **Nomad VMs** | step-ca | HTTPS (443) | Certificate requests |
| **Kasm** | step-ca | HTTPS (443) | Certificate requests |
| **Nomad nodes** | Nomad nodes | TCP 4646-4648 | Cluster management |
| **Nomad nodes** | Nomad nodes | GlusterFS | Replicated storage |
| **Traefik** | Nomad API | HTTP (4646) | Service discovery |
| **Traefik** | step-ca | HTTPS (443) | ACME challenges |
| **Authentik** | Vault | HTTP (8200) | Fetch secrets via WIF |
| **Proxmox** | step-ca | HTTPS (443) | Web UI certificate |
| **labnet-dns** | dns-01 | DNS (53) | Forwarded queries |
| **Clients** | Traefik | HTTPS (443) | Service access |
| **Clients** | DNS Cluster | HTTP (80) | Admin interface |

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

## Nomad Cluster Topology

### Server Node Relationships

All three Nomad nodes are configured as both servers and clients for high availability:

```mermaid
graph TB
    subgraph nomad["Nomad Cluster (dc1)"]
        N1[nomad01<br/>Server+Client - Leader]
        N2[nomad02<br/>Server+Client - Follower]
        N3[nomad03<br/>Server+Client - Follower]

        N1 <-->|Raft Consensus| N2
        N2 <-->|Raft Consensus| N3
        N3 <-->|Raft Consensus| N1
    end

    subgraph storage["Shared Storage"]
        GFS[GlusterFS Volume<br/>/srv/gluster/nomad-data]
    end

    N1 --> GFS
    N2 --> GFS
    N3 --> GFS
```

### Nomad Port Usage

| Port | Protocol | Purpose |
|------|----------|---------|
| 4646 | TCP | HTTP API and UI |
| 4647 | TCP | RPC (server-to-server) |
| 4648 | TCP/UDP | Serf gossip |

### GlusterFS Replication

```mermaid
graph LR
    subgraph gluster["GlusterFS Replicated Volume"]
        B1[Brick 1<br/>nomad01:/srv/gluster/nomad-data]
        B2[Brick 2<br/>nomad02:/srv/gluster/nomad-data]
        B3[Brick 3<br/>nomad03:/srv/gluster/nomad-data]

        B1 <-->|Sync| B2
        B2 <-->|Sync| B3
        B3 <-->|Sync| B1
    end
```

Data written to any node is replicated to all three nodes. Nomad jobs store persistent data here.

## Pi-hole DNS Relationships

### Main DNS Cluster (dns-01, dns-02, dns-03)

```mermaid
graph TD
    subgraph dns_cluster["Main DNS Cluster"]
        DNS01[dns-01<br/>Primary + Gravity Sync]
        DNS02[dns-02<br/>Secondary]
        DNS03[dns-03<br/>Tertiary]
    end

    subgraph stack["DNS Resolution Stack"]
        PH[Pi-hole v6<br/>Port 53]
        UB[Unbound<br/>Port 5335]
    end

    CLIENT[Client Query] --> DNS01
    CLIENT --> DNS02
    CLIENT --> DNS03
    DNS01 -->|Gravity Sync| DNS02
    DNS01 -->|Gravity Sync| DNS03
    PH -->|Recursive| UB
    UB -->|DNS-over-TLS| INTERNET((Internet))
```

### Labnet DNS (labnet-dns-01, labnet-dns-02)

```mermaid
graph TD
    subgraph labnet_dns["Labnet DNS"]
        LDNS01[labnet-dns-01<br/>SDN Primary]
        LDNS02[labnet-dns-02<br/>SDN Secondary]
    end

    LAB_VM[SDN VM] --> LDNS01
    LAB_VM --> LDNS02
    LDNS01 -->|Forward| DNS01[dns-01]
    LDNS02 -->|Forward| DNS01
```

## Vault Workload Identity Federation (WIF)

Nomad jobs authenticate to Vault using JWT-based Workload Identity instead of long-lived tokens:

```mermaid
sequenceDiagram
    participant Job as Nomad Job
    participant Nomad as Nomad Server
    participant Vault as Vault API
    participant JWKS as Nomad JWKS

    Job->>Nomad: Request workload identity
    Nomad->>Nomad: Sign JWT with job metadata
    Nomad-->>Job: Return signed JWT
    Job->>Vault: Authenticate with JWT
    Vault->>JWKS: Fetch public keys
    JWKS-->>Vault: Return JWKS
    Vault->>Vault: Verify JWT signature
    Vault->>Vault: Check role bindings
    Vault-->>Job: Return Vault token
    Job->>Vault: Fetch secrets
    Vault-->>Job: Return secrets
```

Key points:

- No secrets stored on Nomad nodes
- JWT contains job metadata (job ID, task, namespace)
- Vault validates JWT against Nomad's JWKS endpoint
- Each job maps to a Vault role with specific policies

## Certificate Request Flow

When a service needs a TLS certificate:

```mermaid
sequenceDiagram
    participant Service
    participant Traefik
    participant DNS as dns-01
    participant CA as step-ca

    Service->>Traefik: Register with Nomad tags
    Traefik->>Traefik: Detect new service
    Traefik->>DNS: Resolve service FQDN
    DNS-->>Traefik: Return IP address
    Traefik->>CA: ACME HTTP challenge
    CA->>Traefik: Verify challenge
    CA-->>Traefik: Issue certificate
    Traefik->>Service: Route traffic with TLS
```

## Failure Scenarios

### Single Nomad Node Failure

```mermaid
graph TB
    subgraph healthy["Healthy State"]
        H1[nomad01 ✓]
        H2[nomad02 ✓]
        H3[nomad03 ✓]
    end

    subgraph failure["Node Failure"]
        F1[nomad01 ✗]
        F2[nomad02 ✓]
        F3[nomad03 ✓]
    end

    healthy -->|nomad01 fails| failure

    style F1 fill:#f66
```

**Impact:**
- If nomad01 fails: Traefik, Vault, and Authentik become unavailable (pinned to nomad01)
- Cluster remains operational with 2 servers (quorum maintained)
- GlusterFS continues with 2 replicas

**Mitigation:**
- Redeploy jobs without node constraint, or
- Restore nomad01 from backup

### DNS Cluster Failure

**Impact:** DNS resolution fails if all DNS nodes are down.

**Mitigation:**
- Multiple DNS nodes provide redundancy
- Configure secondary DNS in router settings

### Vault Sealed/Failure

**Impact:**
- Authentik cannot fetch secrets (fails to start)
- New certificates can still be issued via Traefik

**Mitigation:**
- Unseal Vault using stored unseal key
- See [Vault Operations](../operations/vault-operations.md)

### Step-CA Failure

**Impact:** New certificates cannot be issued. Existing certificates continue working.

**Mitigation:** Restore from backup. See [Backup & Recovery](../operations/backup-recovery.md).

## Health Check Endpoints

| Service | Health Check | Expected Response |
|---------|--------------|-------------------|
| step-ca | `https://ca.mylab.lan/health` | `{"status":"ok"}` |
| Pi-hole | `http://dns-ip/admin/api.php` | JSON response |
| Nomad | `nomad server members` | Server list |
| Vault | `curl http://nomad01:8200/v1/sys/health` | JSON with `initialized: true` |
| Traefik | `http://nomad01:8081/api/http/routers` | JSON router list |
| Authentik | `http://nomad01:9000/-/health/live/` | HTTP 200 |

## Next Steps

- [:octicons-arrow-right-24: Certificate Chain](certificate-chain.md) - TLS certificate hierarchy
- [:octicons-arrow-right-24: Nomad Operations](../operations/nomad-operations.md) - Managing the cluster
- [:octicons-arrow-right-24: Vault Operations](../operations/vault-operations.md) - Secrets management
- [:octicons-arrow-right-24: Troubleshooting](../troubleshooting/common-issues.md) - When things go wrong
