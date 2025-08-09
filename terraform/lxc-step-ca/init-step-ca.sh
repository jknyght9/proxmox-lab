#!/bin/bash
set -eo pipefail

DNS_POSTFIX="lab"
DNS_NAME="jdclabs.io"

function generate_password () {
    set +o pipefail
    < /dev/urandom tr -dc A-Za-z0-9 | head -c40
    echo
    set -o pipefail
}

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

# Add ACME provider
#step ca provisioner add acme --type ACME