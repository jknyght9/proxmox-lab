#!/bin/sh
# External data source script for Terraform
# Queries Proxmox cluster to detect available nodes

set -eu

# Parse input from Terraform external data source
eval "$(jq -r '@sh "HOST=\(.proxmox_host) KEY=\(.ssh_key)"')"

# Query cluster membership
MEMBERS=$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$HOST" \
  "cat /etc/pve/.members 2>/dev/null" 2>/dev/null || echo "")

if [ -n "$MEMBERS" ] && echo "$MEMBERS" | jq -e '.nodelist' >/dev/null 2>&1; then
  # Multi-node cluster - extract node names and IPs
  NODES=$(echo "$MEMBERS" | jq -c '[.nodelist | to_entries[] | {name: .key, ip: .value.ip}]')
else
  # Single node - get hostname and use provided host IP
  NAME=$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$HOST" hostname 2>/dev/null || echo "pve")
  NODES="[{\"name\":\"$NAME\",\"ip\":\"$HOST\"}]"
fi

# Output in Terraform external data source format
jq -n --argjson nodes "$NODES" '{"nodes": ($nodes | @json)}'
