#!/usr/bin/env bash

# deployCriticalServicesOnly - Deploy only DNS and CA (no VMs)
#
# Deploys Pi-hole DNS with Unbound (DNS-over-TLS) and step-ca Certificate Authority.
# This is a subset of deployAllServices for when you only need infrastructure.
#
# Prerequisites:
#   - cluster-info.json with network configuration
#   - Internet connectivity on all Proxmox nodes
#   - LXC templates available on all nodes
#
# Globals read: DNS_POSTFIX, KEY_PATH, PROXMOX_HOST, CLUSTER_NODE_IPS
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Creates LXC containers for DNS and CA
#   - Updates hosts.json with deployed IPs
#   - Configures DNS records and root certificates
function deployCriticalServicesOnly() {
  cat <<EOF

############################################################################
Critical Services Deployment

Deploying critical infrastructure only: Pi-hole DNS with Unbound (DNS-over-TLS)
and Certificate Authority (Step-CA). No VMs will be deployed.
#############################################################################

EOF

  # Check for and purge existing LXC resources before deployment
  if ! purgeClusterResources --lxc-only; then
    read -rp "$(question "Continue deployment anyway? Resources may conflict. [y/N]: ")" confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && warn "Deployment cancelled" && return 1
  fi

  # Load configuration from cluster-info.json if not already loaded
  if [ -z "$DNS_POSTFIX" ] && [ -f "$CLUSTER_INFO_FILE" ]; then
    DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
  fi

  # If still no DNS_POSTFIX, prompt for it
  if [ -z "$DNS_POSTFIX" ]; then
    read -rp "$(question "Enter DNS domain suffix (e.g., lab.local): ")" DNS_POSTFIX
    while [ -z "$DNS_POSTFIX" ]; do
      warn "DNS domain suffix is required"
      read -rp "$(question "DNS domain suffix: ")" DNS_POSTFIX
    done
  fi

  # Load pre-generated service passwords
  if ! loadServicePasswords; then
    error "Service passwords not generated. Run setup.sh first."
    return 1
  fi
  PIHOLE_PASSWORD="$PIHOLE_ADMIN_PASSWORD"

  # Display configuration summary
  cat <<EOF

======================================
Deployment Configuration:
--------------------------------------
DNS suffix:               $DNS_POSTFIX
Pi-hole admin pass:       [auto-generated]
Credentials file:         $CRYPTO_DIR/service-passwords.json
======================================

EOF

  read -rp "$(question "Proceed with critical services deployment? [Y/n]: ")" CONFIRM
  CONFIRM=${CONFIRM:-Y}
  [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && warn "Deployment cancelled" && return 1

  # Update the step-ca installation script with DNS postfix
  if sed --version >/dev/null 2>&1; then
      sed -i "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
  else
      sed -i '' "s/^DNS_NAME=.*/DNS_NAME=\"$DNS_POSTFIX\"/" terraform/lxc-step-ca/init-step-ca.sh
  fi
  success "Step-CA installation script updated"

  # Generate certificates
  generateCertificates

  # Load cluster info if not already loaded
  if [ ${#CLUSTER_NODES[@]} -eq 0 ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      loadClusterInfo
    else
      detectClusterNodes
    fi
  fi

  # Verify all nodes can reach the internet
  if ! checkClusterConnectivity; then
    error "Cannot proceed without internet connectivity on all nodes."
    return 1
  fi

  # Ensure LXC templates are available on all nodes
  if ! ensureLXCTemplates; then
    error "Cannot proceed without LXC templates on all nodes."
    return 1
  fi

  # Deploy LXC containers (DNS, step-ca)
  cat <<EOF

#############################################################################
LXC Container Deployment

Deploying critical infrastructure: DNS servers and Certificate Authority.
#############################################################################
EOF
  pressAnyKey

  doing "Deploying LXC containers (DNS, step-ca)..."
  docker compose build terraform >/dev/null 2>&1
  docker compose run --rm -it terraform init

  if ! docker compose run --rm -it terraform apply \
    -target=module.dns-main \
    -target=module.dns-labnet \
    -target=module.step-ca; then
    error "LXC container deployment failed"
    read -rp "$(question "Do you want to rollback? [Y/n]: ")" DO_ROLLBACK
    DO_ROLLBACK=${DO_ROLLBACK:-Y}
    if [[ "$DO_ROLLBACK" =~ ^[Yy]$ ]]; then
      rollbackDeployment 1
    fi
    return 1
  fi

  success "LXC containers deployed"

  # Refresh terraform state
  doing "Refreshing Terraform state..."
  docker compose run --rm -T terraform refresh -target=module.dns-main -target=module.dns-labnet -target=module.step-ca >/dev/null 2>&1 || true

  # Generate hosts.json
  doing "Generating hosts.json..."
  if docker compose run --rm -T terraform output -json host-records > hosts.json 2>&1; then
    if jq -e '.external' hosts.json >/dev/null 2>&1; then
      success "hosts.json generated"
    else
      warn "hosts.json contains invalid data, recreating..."
      generateHostsJsonFromModules
    fi
  else
    warn "Could not generate hosts.json, using module outputs..."
    generateHostsJsonFromModules
  fi

  updateDNSRecords
  updateRootCertificates

  displayDeploymentSummary

  success "Critical services deployment complete!"
  info "You can now deploy Nomad (option 5), Kasm (option 6), or both."
}

# ensureCriticalServices - Verify DNS and CA are deployed and accessible
#
# Checks that Pi-hole DNS and step-ca are running and responding to API requests.
# Used as a prerequisite check before deploying VMs or Nomad jobs.
#
# Prerequisites:
#   - hosts.json must exist with dns-01 and step-ca entries
#
# Globals read: KEY_PATH
# Arguments: None
# Returns: 0 if both services healthy, 1 if not deployed or unhealthy
function ensureCriticalServices() {
  if [ ! -f "hosts.json" ]; then
    error "hosts.json not found. Deploy critical services first (option 4)."
    return 1
  fi

  local DNS_IP CA_IP
  DNS_IP=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  CA_IP=$(jq -r '.external[] | select(.hostname == "step-ca") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)

  if [ -z "$DNS_IP" ] || [ "$DNS_IP" = "null" ]; then
    error "DNS not deployed. Run option 4 (Deploy critical services) first."
    return 1
  fi

  if [ -z "$CA_IP" ] || [ "$CA_IP" = "null" ]; then
    error "CA not deployed. Run option 4 (Deploy critical services) first."
    return 1
  fi

  doing "Verifying critical services are reachable..."

  # Verify DNS is actually responding (check if Pi-hole API is accessible)
  if ! curl -s --connect-timeout 5 "http://$DNS_IP/admin/" >/dev/null 2>&1; then
    error "DNS server at $DNS_IP is not responding."
    error "Ensure Pi-hole is running. Deploy critical services first (option 4)."
    return 1
  fi

  # Verify CA is actually responding (check step-ca health endpoint or roots.pem)
  if ! curl -s --connect-timeout 5 -k "https://$CA_IP/health" >/dev/null 2>&1 && \
     ! curl -s --connect-timeout 5 -k "https://$CA_IP/roots.pem" >/dev/null 2>&1; then
    error "CA server at $CA_IP is not responding."
    error "Ensure step-ca is running. Deploy critical services first (option 4)."
    return 1
  fi

  success "DNS ($DNS_IP) and CA ($CA_IP) are running"
  return 0
}