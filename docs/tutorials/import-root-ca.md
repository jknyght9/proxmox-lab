# Importing the Root CA Certificate

All internal services use TLS certificates issued by Vault PKI. Your browser
and operating system do not trust this CA by default, so you will see certificate
warnings when accessing services like `https://vault.<dns-suffix>` or
`https://auth.<dns-suffix>`.

Importing the root CA certificate into your system's trust store eliminates
these warnings.

## Download the Root CA

The root CA certificate is available from the Vault PKI endpoint:

```bash
curl -sk https://<nomad01-ip>:8200/v1/pki/ca/pem -o proxmox-lab-root-ca.crt
```

Or copy it from GlusterFS on any Nomad node:

```bash
scp labadmin@<nomad01-ip>:/srv/gluster/nomad-data/certs/root_ca.crt proxmox-lab-root-ca.crt
```

## macOS

### System-wide (all browsers except Firefox/Zen)

1. Double-click `proxmox-lab-root-ca.crt` — Keychain Access opens
2. Select the **System** keychain (or **login** for current user only)
3. Click **Add**
4. Find the certificate in Keychain Access (search for "Proxmox Lab")
5. Double-click the certificate, expand **Trust**
6. Set **When using this certificate** to **Always Trust**
7. Close the window, enter your password to confirm

Or via command line:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain proxmox-lab-root-ca.crt
```

### Firefox / Zen Browser

Firefox and Zen use their own certificate store — the system keychain is not used.

!!! warning "Zen Browser"
    Zen blocks untrusted CAs entirely with no bypass option. You **must** import
    the root CA for Zen to access any internal HTTPS services.

1. Open **Settings** (or `about:preferences`)
2. Search for **Certificates**
3. Click **View Certificates**
4. Go to the **Authorities** tab
5. Click **Import**, select `proxmox-lab-root-ca.crt`
6. Check **Trust this CA to identify websites**
7. Click **OK**

## Windows

### System-wide

1. Double-click `proxmox-lab-root-ca.crt`
2. Click **Install Certificate**
3. Select **Local Machine** (requires admin), click **Next**
4. Select **Place all certificates in the following store**
5. Click **Browse**, select **Trusted Root Certification Authorities**
6. Click **Next**, then **Finish**

Or via PowerShell (admin):

```powershell
Import-Certificate -FilePath proxmox-lab-root-ca.crt `
  -CertStoreLocation Cert:\LocalMachine\Root
```

### Firefox on Windows

Same as the Firefox steps above — Firefox uses its own store on all platforms.

## Linux

### Debian / Ubuntu

```bash
sudo cp proxmox-lab-root-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

### RHEL / Fedora / CentOS

```bash
sudo cp proxmox-lab-root-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### Arch Linux

```bash
sudo cp proxmox-lab-root-ca.crt /etc/ca-certificates/trust-source/anchors/
sudo trust extract-compat
```

## iOS / iPadOS

1. Transfer `proxmox-lab-root-ca.crt` to the device (AirDrop, email, or web)
2. Open the file — a **Profile Downloaded** notification appears
3. Go to **Settings > General > VPN & Device Management**
4. Tap the profile, then **Install**
5. Go to **Settings > General > About > Certificate Trust Settings**
6. Enable full trust for the root certificate

## Android

1. Transfer `proxmox-lab-root-ca.crt` to the device
2. Go to **Settings > Security > Encryption & credentials**
3. Tap **Install a certificate > CA certificate**
4. Select the file and confirm

## Verification

After importing, verify that your browser trusts the internal CA:

```bash
# Should show the full certificate chain without errors
curl -v https://vault.<dns-suffix>/v1/sys/health 2>&1 | grep "SSL certificate verify ok"

# Or test in browser — no certificate warning should appear
open https://vault.<dns-suffix>
```

## Certificate Renewal

The root CA has a 10-year TTL. The intermediate CA has a 5-year TTL.
Wildcard service certificates have a 1-year TTL and are re-issued by
re-running setup.sh option 1 or the Traefik deploy (d9).

If the root CA is regenerated (full purge + redeploy), you will need to
re-import the new certificate on all client devices.
