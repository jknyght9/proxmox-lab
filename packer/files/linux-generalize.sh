#!/usr/bin/env bash
set -euo pipefail

echo "[+] Generalizing"
sudo rm -f /etc/ssh/ssh_host_*
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id || true
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id || true
sudo systemctl enable ssh || true

sudo tee /etc/systemd/system/regen-ssh-hostkeys.service >/dev/null <<'EOF'
[Unit]
Description=Regenerate SSH host keys if missing
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable regen-ssh-hostkeys.service
