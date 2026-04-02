# Certificate Operations

This page explains how TLS certificates work in Proxmox Lab and covers common certificate management tasks, including issuing, renewing, and regenerating certificates.

---

## Certificate Architecture

Proxmox Lab uses an internal PKI (Public Key Infrastructure) built on **step-ca**:

```
step-ca (Root CA)
  |
  +-- acme.sh (on Nomad/Kasm nodes) --> Node TLS certificates
  |
  +-- Traefik (ACME resolver) --> Service certificates (vault, auth, etc.)
```

### Components

| Component | Role | Location |
|-----------|------|----------|
| **step-ca** | Root Certificate Authority with ACME support | LXC container (VMID 902) |
| **acme.sh** | ACME client on Nomad and Kasm nodes | Installed during Packer template build |
| **Traefik** | Automatic certificate management for Nomad services | Nomad job on nomad01 |
| **Root CA cert** | Trusted root for all internal certificates | `crypto/` directory locally, distributed to nodes |

### Certificate Flow

1. **step-ca** runs as the root CA and exposes an ACME endpoint
2. **Nomad and Kasm nodes** use `acme.sh` to request TLS certificates from step-ca during provisioning
3. **Traefik** uses the step-ca ACME resolver to automatically issue and renew certificates for services it proxies (Vault, Authentik, etc.)
4. **Clients** trust the root CA certificate to validate all downstream certificates

---

## Issuing Certificates with acme.sh

Nomad and Kasm nodes have `acme.sh` pre-installed from the Packer template. Certificates are typically issued automatically during cloud-init provisioning, but you can issue them manually.

### Issue a New Certificate

SSH into the target node and run:

```bash
# Issue a certificate for a hostname
acme.sh --issue \
  --server https://ca.<domain>/acme/acme/directory \
  -d <hostname>.<domain> \
  --standalone \
  --ca-bundle /usr/local/share/ca-certificates/root_ca.crt
```

### Renew Certificates

acme.sh handles renewal automatically via a cron job. To force a renewal:

```bash
acme.sh --renew -d <hostname>.<domain> --force
```

### List Installed Certificates

```bash
acme.sh --list
```

---

## Traefik Automatic Certificate Management

Traefik handles TLS certificates for all services it reverse-proxies. It uses the step-ca ACME resolver configured in the Nomad job.

### How It Works

1. Traefik is configured with a `step-ca` certificate resolver
2. When a new service is discovered via Nomad, Traefik requests a certificate from step-ca using the HTTP-01 ACME challenge
3. Certificates are stored in `/srv/gluster/nomad-data/traefik/acme.json` on the GlusterFS volume
4. Renewal happens automatically before expiry

### Configuration

The Traefik Nomad job configures the ACME resolver:

```
--certificatesresolvers.step-ca.acme.httpchallenge=true
--certificatesresolvers.step-ca.acme.httpchallenge.entrypoint=web
--certificatesresolvers.step-ca.acme.caserver=https://ca.<domain>/acme/acme/directory
```

Traefik trusts the root CA through environment variables:

- `SSL_CERT_FILE=/data/certs/root_ca.crt`
- `LEGO_CA_CERTIFICATES=/data/certs/root_ca.crt`

### Viewing Issued Certificates

Check the Traefik dashboard at `http://<nomad01-ip>:8081/dashboard/` to see active certificates, or query the API:

```bash
curl http://<nomad01-ip>:8081/api/http/routers | jq '.[].tls'
```

---

## Regenerating the Certificate Authority

If you need to regenerate the entire CA (e.g., if the root key is compromised or certificates have expired beyond renewal), use setup.sh menu option 11.

```bash
./setup.sh
# Select option 11: Regenerate CA
```

### What This Does

1. Destroys and recreates the step-ca LXC container
2. Generates a new root CA key pair
3. Issues a new root CA certificate
4. Stores the new root CA certificate in `crypto/`

!!! danger "Breaking change"
    Regenerating the CA invalidates **all existing certificates** in the lab. After regeneration you must:

    1. Update root certificates on all Proxmox nodes (menu option 12)
    2. Reissue certificates on all Nomad and Kasm nodes
    3. Clear the Traefik ACME store so it requests new certificates
    4. Redistribute the root CA to any workstations that trust it

---

## Updating Root Certificates on Proxmox Nodes

After regenerating the CA or on initial setup, push the root CA certificate to all Proxmox cluster nodes:

```bash
./setup.sh
# Select option 12: Update root certificates
```

This copies the root CA certificate to each Proxmox node and updates the system trust store.

---

## Installing the Root CA on Workstations

To avoid browser security warnings when accessing internal services, install the root CA certificate on your workstation.

The root CA certificate is located at `crypto/root_ca.crt` in the project directory.

### macOS

```bash
# Add to system keychain
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  crypto/root_ca.crt
```

Alternatively, double-click the `root_ca.crt` file to open it in Keychain Access, then set it to "Always Trust".

### Linux (Debian/Ubuntu)

```bash
# Copy the certificate
sudo cp crypto/root_ca.crt /usr/local/share/ca-certificates/lab-root-ca.crt

# Update the certificate store
sudo update-ca-certificates
```

### Linux (RHEL/Fedora)

```bash
# Copy the certificate
sudo cp crypto/root_ca.crt /etc/pki/ca-trust/source/anchors/lab-root-ca.crt

# Update the certificate store
sudo update-ca-trust
```

### Windows

```powershell
# Run in an elevated PowerShell
Import-Certificate -FilePath crypto\root_ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

Alternatively, double-click the `.crt` file and install it into the "Trusted Root Certification Authorities" store.

### Browser-Specific Notes

- **Chrome/Edge**: uses the system certificate store on all platforms
- **Firefox**: maintains its own certificate store; import via **Settings > Privacy & Security > View Certificates > Authorities > Import**

---

## Certificate Verification

### Verify the Root CA

```bash
openssl x509 -in crypto/root_ca.crt -text -noout
```

### Test a Service Certificate

```bash
# Check the certificate served by a service
openssl s_client -connect vault.<domain>:443 -servername vault.<domain> </dev/null 2>/dev/null | openssl x509 -text -noout

# Verify the certificate chain
openssl s_client -connect vault.<domain>:443 -CAfile crypto/root_ca.crt -servername vault.<domain> </dev/null
```

### Check Certificate Expiry

```bash
# Check when a certificate expires
openssl s_client -connect vault.<domain>:443 -servername vault.<domain> </dev/null 2>/dev/null | openssl x509 -noout -enddate
```

---

## Clearing Traefik ACME Store

If Traefik has stale or invalid certificates (e.g., after a CA regeneration), clear the ACME store:

```bash
# SSH into nomad01
ssh user@<nomad01-ip>

# Remove the ACME certificate store
sudo rm /srv/gluster/nomad-data/traefik/acme.json

# Restart the Traefik job
docker compose run --rm nomad job stop -purge traefik
docker compose run --rm nomad job run /nomad/jobs/traefik.nomad.hcl
```

Traefik will re-request certificates for all services on startup.

---

## Common Certificate Tasks

| Task | Method |
|------|--------|
| Issue a new node certificate | `acme.sh --issue` on the target node |
| Renew a node certificate | `acme.sh --renew -d <host> --force` |
| Issue a service certificate | Automatic via Traefik when the service registers in Nomad |
| Regenerate the entire CA | setup.sh menu option 11 |
| Push root CA to Proxmox nodes | setup.sh menu option 12 |
| Install root CA on workstation | See platform-specific instructions above |
| Clear stale Traefik certs | Delete `acme.json` and restart the Traefik job |
