#!/usr/bin/env bash

function rollbackDeployment() {
  local phase="${1:-$DEPLOY_PHASE}"

  warn "Deployment failed at phase $phase. Rolling back..."
  echo

  # Phase order: 1=Packer, 2=Nomad VMs, 3=Vault, 4=DNS+Kasm
  case $phase in
    4)
      # Phase 4 failed: Destroy DNS + Kasm, keep Nomad/Vault
      doing "Rolling back Phase 4: Destroying DNS and Kasm..."
      docker compose run --rm terraform destroy \
        -target=module.dns-main \
        -target=module.kasm \
        -auto-approve 2>/dev/null || true

      # Clean up orphaned LXC containers
      for VMID in 909 910 911 912 920 921 922; do
        sshRun "$REMOTE_USER" "$PROXMOX_HOST" \
          "pct stop $VMID 2>/dev/null; pct destroy $VMID 2>/dev/null" 2>/dev/null || true
      done
      warn "DNS and Kasm destroyed. Nomad cluster and Vault preserved."
      ;;
    3)
      # Phase 3 failed: Vault deployment — nothing to destroy in Terraform,
      # Vault is a Nomad job. Just clean up credentials.
      doing "Rolling back Phase 3: Cleaning Vault artifacts..."
      rm -f terraform/vault.auto.tfvars crypto/vault-credentials.json 2>/dev/null || true
      warn "Vault credentials cleaned. Nomad cluster preserved."
      ;;
    2)
      # Phase 2 failed: Destroy Nomad VMs
      doing "Rolling back Phase 2: Destroying Nomad VMs..."
      docker compose run --rm terraform destroy \
        -target=module.nomad \
        -auto-approve 2>/dev/null || true

      # Clean up orphaned VM IDs
      for VMID in 905 906 907; do
        for node_ip in "${CLUSTER_NODE_IPS[@]}"; do
          sshRun "$REMOTE_USER" "$node_ip" \
            "qm stop $VMID 2>/dev/null; qm destroy $VMID 2>/dev/null" 2>/dev/null || true
        done
      done
      warn "Nomad VMs destroyed."
      ;;
    1)
      # Phase 1 failed: Clean up Packer artifacts
      doing "Rolling back Phase 1: Cleaning Packer artifacts..."
      rm -rf packer/packer-outputs 2>/dev/null || true
      warn "Packer artifacts cleaned."
      ;;
    0)
      info "Nothing to roll back (deployment not started)."
      ;;
  esac

  DEPLOY_PHASE=0
  echo
  error "Rollback complete. Please review the errors above and try again."
}