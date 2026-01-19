#!/bin/bash

set -e
export DEBIAN_FRONTEND=noninteractive
export TERM=dumb

ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme123}"

echo "[+] Updating APT and installing requirements..."
apt-get update
apt-get install -y curl wget apt-transport-https dnsutils jq

echo "[+] Installing Technitium DNS Server..."
curl -sSL https://download.technitium.com/dns/install.sh | bash

echo "[+] Waiting for Technitium DNS to start..."
sleep 10

echo "[+] Configuring admin password..."
# Get initial token (first login uses admin/admin)
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=admin" | jq -r '.token // empty')

if [ -n "$TOKEN" ]; then
    # Change admin password
    curl -s "http://127.0.0.1:5380/api/user/changePassword?token=${TOKEN}&pass=${ADMIN_PASSWORD}" > /dev/null
    echo "[+] Admin password changed successfully"
else
    echo "[!] Could not get initial token - service may need more time to start"
fi

echo "[+] Enabling DNS service to start on boot..."
systemctl enable dns

echo -e "[✓] Technitium DNS Installation Complete\n"
