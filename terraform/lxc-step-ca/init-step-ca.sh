#!/bin/bash
set -eo pipefail

DNS_POSTFIX="lab"
DNS_NAME="jdclabs.lan"

CA_CFG="/etc/step-ca/config/ca.json"
ROOT_CERT="/etc/step-ca/certs/root_ca.crt"
INT_CERT="/etc/step-ca/certs/intermediate_ca.crt"
INT_KEY="/etc/step-ca/secrets/intermediate_ca_key"
PASSWORD_FILE="/etc/step-ca/secrets/password_file"

function generate_password () {
    set +o pipefail
    < /dev/urandom tr -dc A-Za-z0-9 | head -c40
    echo
    set -o pipefail
}

# Install requirements (Alpine-based image uses apk)
# Note: step CLI is already available in smallstep/step-ca image
apk add --no-cache jq

# Check if CA is already initialized AND password can decrypt keys
if [[ -f "$CA_CFG" && -f "$ROOT_CERT" && -f "$INT_CERT" && -f "$PASSWORD_FILE" && -f "$INT_KEY" ]]; then
    # Verify password can decrypt the intermediate key
    if step crypto key inspect "$INT_KEY" --password-file="$PASSWORD_FILE" >/dev/null 2>&1; then
        echo "[✓] Step-CA already initialized, credentials verified"
        echo "    Root cert: $ROOT_CERT"
        echo "    Intermediate cert: $INT_CERT"
        echo "    Config: $CA_CFG"
        exit 0
    else
        echo "[!] Password mismatch detected - CA credentials are out of sync"
        if [[ "${FORCE_REGENERATE:-0}" != "1" ]]; then
            echo "    The password file cannot decrypt the existing keys."
            echo "    Run with FORCE_REGENERATE=1 to wipe and regenerate all CA files."
            exit 1
        fi
    fi
fi

# If FORCE_REGENERATE is set, wipe existing CA files first
if [[ "${FORCE_REGENERATE:-0}" == "1" ]]; then
    echo "[!] Force regeneration requested - wiping existing CA files"
    rm -rf /etc/step-ca/config /etc/step-ca/certs /etc/step-ca/secrets
fi

echo "[+] Initializing Step-CA..."

# Generate password for keys
mkdir -p /etc/step-ca/secrets
generate_password > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

# Generate certificates
step ca init \
  --deployment-type standalone \
  --name proxmox-lab \
  --address ':443' \
  --dns "ca.$DNS_NAME" \
  --provisioner 'admin@lab.com' \
  --password-file "$PASSWORD_FILE" \
  --acme

# Update ACME configuration allowing longer duration certs
tmp=$(mktemp)

jq '
  .authority.provisioners |=
  map(if .type=="ACME" and .name=="acme" then
        .claims = (.claims // {}) +
          {defaultTLSCertDuration:"2160h", maxTLSCertDuration:"2160h"}
      else . end)
' "$CA_CFG" >"$tmp" && mv "$tmp" "$CA_CFG"

echo "[✓] Step-CA initialization complete"