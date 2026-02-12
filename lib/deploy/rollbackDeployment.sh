#!/usr/bin/env bash

function rollbackDeployment() {
  local phase="${1:-$DEPLOY_PHASE}"

  warn "Deployment failed at phase $phase. Rolling back..."
  echo

  case $phase in
    3)
      # Phase 3 failed: Destroy VMs only, keep LXC infrastructure
      doing "Rolling back Phase 3: Destroying VMs..."
      docker compose run --rm terraform destroy \
        -target=module.nomad \
        -target=module.kasm \
        -auto-approve 2>/dev/null || true
      warn "VMs destroyed. LXC infrastructure (DNS, step-ca) preserved."
      ;;
    2)
      # Phase 2 failed: Clean up any partial Packer artifacts
      doing "Rolling back Phase 2: Cleaning Packer artifacts..."
      rm -rf packer/packer-outputs 2>/dev/null || true
      warn "Packer artifacts cleaned."

      read -rp "$(question "Do you want to also destroy LXC containers (DNS, step-ca)? [y/N]: ")" DESTROY_LXC
      if [[ "$DESTROY_LXC" =~ ^[Yy]$ ]]; then
        rollbackDeployment 1
      else
        info "LXC infrastructure preserved. You can retry Packer build."
      fi
      ;;
    1)
      # Phase 1 failed: Destroy all LXC containers
      doing "Rolling back Phase 1: Destroying LXC containers..."
      docker compose run --rm terraform destroy \
        -target=module.dns-main \
        -target=module.dns-labnet \
        -target=module.step-ca \
        -auto-approve 2>/dev/null || true

      # Also clean up any LXC VMIDs that might be orphaned (dns + step-ca)
      for VMID in 902 909 910 911 912 920 921 922; do
        ssh -i "$KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE_USER@$PROXMOX_HOST" \
          "pct stop $VMID 2>/dev/null; pct destroy $VMID 2>/dev/null" 2>/dev/null || true
      done
      warn "LXC containers destroyed."
      ;;
    0)
      info "Nothing to roll back (deployment not started)."
      ;;
  esac

  DEPLOY_PHASE=0
  echo
  error "Rollback complete. Please review the errors above and try again."
}