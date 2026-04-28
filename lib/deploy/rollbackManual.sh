#!/usr/bin/env bash

# resetDNSToGateway - Reset DNS on Nomad VMs and Proxmox nodes to the gateway
#
# Layer 2 manages DNS config — tearing it down leaves everything pointing at
# Pi-hole IPs that may not work without the full stack running.
#
# Arguments: $1 - "all" to include Nomad VMs (default), "proxmox" for nodes only
function resetDNSToGateway() {
  local scope="${1:-all}"
  local GATEWAY_IP
  GATEWAY_IP=$(jq -r '.network.external.gateway // empty' "$CLUSTER_INFO_FILE" 2>/dev/null)
  GATEWAY_IP="${GATEWAY_IP:-10.1.50.1}"

  doing "Resetting DNS to gateway ($GATEWAY_IP)..."

  # Reset Nomad VMs
  if [ "$scope" = "all" ]; then
    local NOMAD_IPS
    NOMAD_IPS=$(sed -n 's/.*ip = "\([^"]*\)".*/\1/p' terraform/vm-nomad/variables.tf 2>/dev/null)
    for ip in $NOMAD_IPS; do
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -i "$ADMIN_KEY_PATH" "labadmin@${ip}" \
        "sudo resolvectl dns eth0 $GATEWAY_IP" 2>/dev/null || true
    done
  fi

  # Reset Proxmox nodes
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    local node_count
    node_count=$(jq -r '.nodes | length' "$CLUSTER_INFO_FILE" 2>/dev/null || echo 0)
    for i in $(seq 0 $((node_count - 1))); do
      local node_name node_ip
      node_name=$(jq -r ".nodes[$i].name" "$CLUSTER_INFO_FILE" 2>/dev/null)
      node_ip=$(jq -r ".nodes[$i].ip" "$CLUSTER_INFO_FILE" 2>/dev/null)
      if [ -n "$node_ip" ] && [ "$node_ip" != "null" ]; then
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
          -i "$ENTERPRISE_KEY_PATH" "root@${node_ip}" \
          "pvesh set /nodes/$node_name/dns -dns1 $GATEWAY_IP" 2>/dev/null || true
      fi
    done
  fi

  success "DNS reset to gateway ($GATEWAY_IP)"
}

# rollbackLayer2 - Destroy all Layer 2 resources (services)
#
# Runs terraform destroy on Layer 2, stopping all Nomad jobs and removing
# Vault configuration, DNS records, secrets, and TLS certificates.
# Infrastructure (VMs, LXCs) remains intact — redeploy with option 1
# starting from Phase 3 (Vault init) or run d5 to reapply Layer 2.
#
# Also cleans Layer 2 state so the next apply starts fresh.
function rollbackLayer2() {
  cat <<EOF

#############################################################################
Rollback Layer 2 — Services

This will destroy all service configuration:
  - Nomad jobs (Traefik, Authentik, Samba AD, Uptime Kuma, etc.)
  - Vault PKI, JWT auth, policies, and secrets
  - TLS certificates
  - DNS records
  - Authentik apps/providers/outposts

Infrastructure (Nomad VMs, DNS containers, Kasm) will remain intact.
After rollback, re-run option 1 or use d5 to redeploy services.
#############################################################################

EOF

  read -rp "$(question "Are you sure? [y/N]: ")" CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    info "Cancelled"
    return 0
  fi

  # Try Terraform destroy if state exists
  if [ -f "$SCRIPT_DIR/terraform/services/terraform.tfstate" ]; then
    doing "Destroying Layer 2 via Terraform..."
    tf-services init >/dev/null 2>&1
    tf-services destroy -auto-approve || true
  else
    info "No Terraform state — skipping terraform destroy"
  fi

  # Always stop Nomad jobs directly as fallback (handles missing/stale state)
  doing "Stopping Layer 2 Nomad jobs..."
  local NOMAD01_IP
  NOMAD01_IP=$(sed -n 's/.*ip = "\([^"]*\)".*/\1/p' terraform/vm-nomad/variables.tf 2>/dev/null | head -1)
  NOMAD01_IP="${NOMAD01_IP:-10.1.50.114}"

  local LAYER2_JOBS="traefik authentik samba-ad uptime-kuma lam netbox docs backup tailscale"
  for job in $LAYER2_JOBS; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      -i "$ADMIN_KEY_PATH" "labadmin@${NOMAD01_IP}" \
      "nomad job status $job" &>/dev/null; then
      doing "  Stopping $job..."
      ssh -o StrictHostKeyChecking=no -i "$ADMIN_KEY_PATH" "labadmin@${NOMAD01_IP}" \
        "nomad job stop -purge $job" 2>/dev/null || true
    fi
  done

  # Reset DNS on Nomad VMs and Proxmox nodes back to gateway
  resetDNSToGateway "all"

  # Clean state so next apply starts fresh
  doing "Cleaning Layer 2 state..."
  rm -f terraform/services/terraform.tfstate terraform/services/terraform.tfstate.backup
  rm -f terraform/services/terraform.tfstate.*.backup
  success "Layer 2 destroyed — infrastructure still intact"
}

# rollbackLayer1 - Destroy all Layer 1 resources (infrastructure)
#
# Runs terraform destroy on Layer 1, removing all VMs and LXC containers.
# This also invalidates Layer 2 since the infrastructure it runs on is gone.
# GlusterFS data lives on VM disks — destroying VMs wipes all service data.
#
# After rollback, re-run option 1 from Phase 1 (Packer) or Phase 2 (VMs).
# Packer templates are preserved by default (they take time to rebuild).
function rollbackLayer1() {
  cat <<EOF

#############################################################################
Rollback Layer 1 — Infrastructure

This will destroy ALL VMs and LXC containers:
  - Nomad cluster (nomad01, nomad02, nomad03)
  - DNS cluster (dns-01, dns-02, dns-03)
  - Labnet DNS (labnet-dns-01, labnet-dns-02)
  - Kasm Workspaces (if deployed)

WARNING: GlusterFS data lives on VM disks. Destroying VMs wipes ALL
service data (Vault, Authentik DB, Samba AD, etc.).

Layer 2 state will also be cleaned (services ran on this infrastructure).
Packer templates (9001, 9002) are preserved unless you choose to remove them.
#############################################################################

EOF

  read -rp "$(question "Type 'DESTROY' to confirm: ")" CONFIRM
  if [ "$CONFIRM" != "DESTROY" ]; then
    info "Cancelled"
    return 0
  fi

  # Destroy Layer 2 first (if state exists) — clean shutdown of services
  if [ -f "$SCRIPT_DIR/terraform/services/terraform.tfstate" ]; then
    doing "Destroying Layer 2 first (clean service shutdown)..."
    tf-services init >/dev/null 2>&1
    tf-services destroy -auto-approve || true
    rm -f terraform/services/terraform.tfstate terraform/services/terraform.tfstate.backup
  fi

  # Reset Proxmox DNS to gateway BEFORE destroying infra
  # (DNS containers are about to be destroyed — Nomad VMs too, so proxmox only)
  resetDNSToGateway "proxmox"

  # Destroy Layer 1
  doing "Destroying Layer 1 (VMs and LXC containers)..."
  tf init >/dev/null 2>&1
  tf destroy -auto-approve || true

  # Clean Layer 2 tfvars (Vault addresses are now invalid)
  rm -f terraform/services/terraform.tfvars
  rm -f terraform/services/terraform.tfstate terraform/services/terraform.tfstate.backup

  # Clean runtime state
  rm -f hosts.json crypto/vault-credentials.json

  success "Layer 1 destroyed — all VMs and containers removed"

  # Optionally remove Packer templates
  echo
  read -rp "$(question "Also remove Packer templates (9001, 9002)? They take time to rebuild. [y/N]: ")" REMOVE_TEMPLATES
  if [[ "$REMOVE_TEMPLATES" =~ ^[Yy]$ ]]; then
    if [ -z "${PROXMOX_HOST:-}" ]; then
      if [ -f "$CLUSTER_INFO_FILE" ]; then
        loadClusterInfo
        if [ -z "${PROXMOX_HOST:-}" ] && [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
          PROXMOX_HOST="${CLUSTER_NODE_IPS[0]}"
        fi
      fi
    fi

    if [ -n "${PROXMOX_HOST:-}" ]; then
      doing "Removing Packer templates..."
      removeTemplateIfExists 9001 "docker-template"
      removeTemplateIfExists 9002 "nomad-template"
      success "Packer templates removed"
    else
      warn "Cannot determine Proxmox host — remove templates manually"
    fi
  else
    info "Packer templates preserved"
  fi
}
