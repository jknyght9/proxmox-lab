#!/usr/bin/env bash

# Display a summary of all deployed resources with access URLs and credential locations
function displayDeploymentSummary() {
  if [ ! -f "hosts.json" ]; then
    warn "hosts.json not found - cannot display deployment summary"
    return 1
  fi

  # Load DNS_POSTFIX if not set
  if [ -z "$DNS_POSTFIX" ] && [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
  fi

  echo
  echo "=============================================================================="
  echo "  DEPLOYED RESOURCES SUMMARY"
  echo "=============================================================================="
  echo

  local has_resources=false

  # Pi-hole DNS servers
  local dns_hosts
  dns_hosts=$(jq -r '.external[] | select(.hostname | startswith("dns-")) | "\(.hostname):\(.ip)"' hosts.json 2>/dev/null)
  if [ -n "$dns_hosts" ]; then
    has_resources=true
    echo "  Pi-hole DNS"
    echo "  -----------"
    while IFS=: read -r hostname ip; do
      ip_clean=$(echo "$ip" | cut -d'/' -f1)
      printf "    %-10s %-15s http://%s/admin   %s.%s\n" "$hostname:" "$ip_clean" "$ip_clean" "$hostname" "${DNS_POSTFIX:-local}"
    done <<< "$dns_hosts"
    echo "    Ports: 53/UDP (DNS), 80/HTTP (Admin)"
    echo "    Credentials: terraform/terraform.tfvars (pihole_admin_password)"
    echo
  fi

  # Nomad Cluster
  local nomad_hosts
  nomad_hosts=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | "\(.hostname):\(.ip)"' hosts.json 2>/dev/null)
  if [ -n "$nomad_hosts" ]; then
    has_resources=true
    echo "  Nomad Cluster"
    echo "  -------------"
    while IFS=: read -r hostname ip; do
      ip_clean=$(echo "$ip" | cut -d'/' -f1)
      printf "    %-10s %-15s http://%s:4646   %s.%s\n" "$hostname:" "$ip_clean" "$ip_clean" "$hostname" "${DNS_POSTFIX:-local}"
    done <<< "$nomad_hosts"
    echo "    Credentials: No authentication required"
    echo
  fi

  # Kasm Workspaces
  local kasm_host
  kasm_host=$(jq -r '.external[] | select(.hostname | startswith("kasm")) | "\(.hostname):\(.ip)"' hosts.json 2>/dev/null)
  if [ -n "$kasm_host" ]; then
    has_resources=true
    local hostname ip ip_clean
    hostname=$(echo "$kasm_host" | cut -d: -f1)
    ip=$(echo "$kasm_host" | cut -d: -f2)
    ip_clean=$(echo "$ip" | cut -d'/' -f1)
    echo "  Kasm Workspaces"
    echo "  ---------------"
    printf "    %-10s %-15s https://%s       kasm.%s\n" "$hostname:" "$ip_clean" "$ip_clean" "${DNS_POSTFIX:-local}"
    echo "    Credentials: terraform/terraform.tfvars (kasm_admin_password)"
    echo
  fi

  # Traefik (check Nomad job status)
  if isTraefikDeployed 2>/dev/null; then
    has_resources=true
    local nomad_ip
    nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
    echo "  Traefik (Load Balancer)"
    echo "  -----------------------"
    echo "    Dashboard: http://$nomad_ip:8081/dashboard/"
    echo "    HTTP:      Port 80"
    echo "    HTTPS:     Port 443"
    echo "    Credentials: No authentication required"
    echo
  fi

  # Vault (check Nomad job status)
  if isVaultDeployed 2>/dev/null; then
    has_resources=true
    local nomad_ip
    nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
    echo "  Vault (Secrets Manager + PKI CA)"
    echo "  ---------------------------------"
    echo "    UI:        https://vault.${DNS_POSTFIX:-local}/"
    echo "    Direct:    http://$nomad_ip:8200/"
    echo "    PKI:"
    echo "      Root CA:   http://$nomad_ip:8200/v1/pki/ca/pem"
    echo "      ACME:      https://vault.${DNS_POSTFIX:-local}/v1/pki_int/acme/directory"
    echo "    Credentials: crypto/vault-credentials.json"
    echo
  fi

  # Authentik (check Nomad job status)
  if isAuthentikDeployed 2>/dev/null; then
    has_resources=true
    local nomad_ip
    nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)
    echo "  Authentik (Identity Provider)"
    echo "  -----------------------------"
    echo "    UI:        https://auth.${DNS_POSTFIX:-local}/"
    echo "    Direct:    http://$nomad_ip:9000/"
    echo "    Setup:     https://auth.${DNS_POSTFIX:-local}/if/flow/initial-setup/"
    echo
  fi

  if [ "$has_resources" = "false" ]; then
    warn "No deployed resources found"
    return 1
  fi

  echo "------------------------------------------------------------------------------"
  echo "  Domain: ${DNS_POSTFIX:-not set}"
  echo "  Credentials:"
  echo "    - Service passwords: crypto/service-passwords.json"
  echo "    - Terraform config:  terraform/terraform.tfvars"
  if [ -f "crypto/vault-credentials.json" ]; then
    echo "    - Vault credentials: crypto/vault-credentials.json"
  fi
  echo "=============================================================================="
}

