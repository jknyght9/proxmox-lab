#!/bin/bash
set -eo pipefail

DNS_POSTFIX="lab"
DNS_NAME="jdclabs.lan"

function generate_password () {
    set +o pipefail
    < /dev/urandom tr -dc A-Za-z0-9 | head -c40
    echo
    set -o pipefail
}

# Install requirements
apt-get update
apt-get install jq -y

# Generate password for keys
mkdir -p /etc/step-ca/secrets
generate_password > /etc/step-ca/secrets/password_file
chmod 600 /etc/step-ca/secrets/password_file

# Generate certificates
step ca init \
  --deployment-type standalone \
  --name proxmox-lab \
  --address ':443' \
  --dns "ca.$DNS_NAME" \
  --provisioner 'admin@lab.com' \
  --password-file /etc/step-ca/secrets/password_file \
  --acme

# Update ACME configuration allowing longer duration certs
CA_CFG="/etc/step-ca/config/ca.json"
tmp=$(mktemp)

jq '
  .authority.provisioners |=
  map(if .type=="ACME" and .name=="acme" then
        .claims = (.claims // {}) +
          {defaultTLSCertDuration:"2160h", maxTLSCertDuration:"2160h"}
      else . end)
' "$CA_CFG" >"$tmp" && mv "$tmp" "$CA_CFG"