#!/usr/bin/env bash

function rollbackManual() {
  cat <<EOF

#############################################################################
Rollback Service Deployment (Terraform)

  1) Rollback LXC containers (DNS, CA)
  2) Rollback VMs (Nomad, Kasm)
  0) Back to main menu
#############################################################################

EOF

  read -rp "$(question "Select option [0-2]: ")" OPTION
  case $OPTION in
    0)
      SKIP_PAUSE=true
      return 0
      ;;
    1)
      echo
      warn "This will DESTROY the following LXC containers:"
      echo "  - DNS cluster (dns-01, dns-02, dns-03)"
      echo "  - Labnet DNS cluster (labnet-dns-01, labnet-dns-02)"
      echo "  - Step-CA (Certificate Authority)"
      echo
      read -rp "$(question "Are you sure you want to proceed? [y/N]: ")" CONFIRM
      if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Operation cancelled"
        return 0
      fi

      doing "Destroying LXC containers (DNS, step-ca)..."
      docker compose run --rm terraform destroy \
        -target=module.dns-main \
        -target=module.dns-labnet \
        -target=module.step-ca \
        -auto-approve 2>/dev/null || true
      success "LXC containers destroyed"
      ;;
    2)
      echo
      warn "This will DESTROY the following VMs:"
      echo "  - Nomad cluster (nomad01, nomad02, nomad03)"
      echo "  - Kasm Workspaces (kasm01)"
      echo
      read -rp "$(question "Are you sure you want to proceed? [y/N]: ")" CONFIRM
      if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Operation cancelled"
        return 0
      fi

      doing "Destroying VMs (Nomad, Kasm)..."
      docker compose run --rm terraform destroy \
        -target=module.nomad \
        -target=module.kasm \
        -auto-approve 2>/dev/null || true
      success "VMs destroyed"

      # Ask about Packer templates (only relevant when destroying VMs)
      echo
      read -rp "$(question "Also remove Packer templates (9001, 9002)? These take time to rebuild. [y/N]: ")" REMOVE_TEMPLATES
      if [[ "$REMOVE_TEMPLATES" =~ ^[Yy]$ ]]; then
        # Load cluster context if needed
        if [ -z "$PROXMOX_HOST" ]; then
          if [ -f "$CLUSTER_INFO_FILE" ]; then
            loadClusterInfo
            if [ -z "$PROXMOX_HOST" ] && [ ${#CLUSTER_NODE_IPS[@]} -gt 0 ]; then
              PROXMOX_HOST="${CLUSTER_NODE_IPS[0]}"
            fi
          fi
        fi

        if [ -z "$PROXMOX_HOST" ]; then
          error "Cannot determine Proxmox host. Cluster info not found."
          return 1
        fi

        doing "Removing Packer templates from shared storage..."
        removeTemplateIfExists 9001 "docker-template"
        removeTemplateIfExists 9002 "nomad-template"
        success "Packer templates removed"
      else
        info "Packer templates preserved"
      fi
      ;;
    *)
      error "Invalid option"
      return 1
      ;;
  esac
}