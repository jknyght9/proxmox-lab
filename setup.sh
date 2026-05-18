#!/usr/bin/env bash
#
# Proxmox Lab — Interactive setup menu
#
# Two-layer Terraform architecture:
#   Layer 1 (terraform/)          — Infrastructure: VMs, LXCs, GlusterFS, Vault job
#   Layer 2 (terraform/services/) — Services: Vault config, Nomad jobs, secrets, PKI
#
# Usage:
#   ./setup.sh               # interactive menu
#   ./setup.sh --dev         # includes developer tools

set -euo pipefail
export TERM=xterm

# Resolve project directory (script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# Library sourcing (only what's still needed)
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/bootstrap.sh"
source "$SCRIPT_DIR/lib/credentials.sh"

source "$SCRIPT_DIR/lib/proxmox/clusterHelpers.sh"
source "$SCRIPT_DIR/lib/proxmox/configureProxmox.sh"
source "$SCRIPT_DIR/lib/proxmox/purgeClusterResources.sh"
source "$SCRIPT_DIR/lib/proxmox/selectSharedStorage.sh"
source "$SCRIPT_DIR/lib/proxmox/ssh.sh"
source "$SCRIPT_DIR/lib/proxmox/templateHelpers.sh"

source "$SCRIPT_DIR/lib/packerHelpers.sh"
source "$SCRIPT_DIR/lib/deploy/purgeDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackDeployment.sh"
source "$SCRIPT_DIR/lib/deploy/rollbackManual.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/initVault.sh"
source "$SCRIPT_DIR/lib/deploy/nomadJob/unsealVault.sh"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
DEV_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--dev" ]] && DEV_MODE=true
done

# -----------------------------------------------------------------------------
# Global state
# -----------------------------------------------------------------------------
CRYPTO_DIR="$SCRIPT_DIR/crypto"
ENTERPRISE_KEY_NAME="labenterpriseadmin"
ENTERPRISE_KEY_PATH="$CRYPTO_DIR/$ENTERPRISE_KEY_NAME"
ENTERPRISE_PUBKEY_PATH="$ENTERPRISE_KEY_PATH.pub"
ADMIN_KEY_NAME="labadmin"
ADMIN_KEY_PATH="$CRYPTO_DIR/$ADMIN_KEY_NAME"
ADMIN_PUBKEY_PATH="$ADMIN_KEY_PATH.pub"
REMOTE_USER="root"
CLUSTER_INFO_FILE="$SCRIPT_DIR/cluster-info.json"
VAULT_CREDENTIALS_FILE="$CRYPTO_DIR/vault-credentials.json"

# Cluster globals — populated by discoverCluster / loadClusterInfo
CLUSTER_NODES=()
CLUSTER_NODE_IPS=()
IS_CLUSTER=false
USE_SHARED_STORAGE=false
TEMPLATE_STORAGE=""
NETWORK_BRIDGE=""

# Deployment phase tracking for rollback
DEPLOY_PHASE=0

# -----------------------------------------------------------------------------
# Terraform Helpers
# -----------------------------------------------------------------------------

# Run terraform in Layer 1 (infrastructure)
function tf() {
  docker compose run --rm -it terraform "$@"
}

# Run terraform in Layer 2 (services)
function tf-services() {
  docker compose run --rm -it terraform-services "$@"
}

# Re-run the tfvars/pkrvars generators against the current cluster
# discovery snapshot. Cheap and idempotent — call before any operation
# that depends on bootstrap-derived variables matching the latest code
# (e.g. when a new variable is added between releases). No SSH or
# Proxmox API calls; just rewrites the local files.
function refreshGeneratedConfigs() {
  ensureBootstrapComplete || return 1
  _bootstrap_init_vars
  ensureClusterContext || {
    error "Cannot refresh tfvars — cluster-info.json missing or unreadable"
    return 1
  }
  readBootstrapConfig || {
    error "Cannot refresh tfvars — bootstrap.yml missing or invalid"
    return 1
  }
  # Storage selections come from cluster-info.json (saved during initial
  # bootstrap). We don't re-prompt here.
  TEMPLATE_STORAGE=$(jq -r '.storage.templates // ""' "$CLUSTER_INFO_FILE")
  TEMPLATE_STORAGE_TYPE=$(jq -r '.storage.templates_type // ""' "$CLUSTER_INFO_FILE")
  RUNTIME_STORAGE=$(jq -r '.storage.runtime // ""' "$CLUSTER_INFO_FILE")
  LXC_STORAGE=$(jq -r '.storage.lxc // ""' "$CLUSTER_INFO_FILE")
  SNIPPET_STORAGE=$(jq -r '.storage.snippets // ""' "$CLUSTER_INFO_FILE")
  VZTMPL_STORAGE=$(jq -r '.storage.vztmpl // ""' "$CLUSTER_INFO_FILE")
  PRIMARY_NODE=$(jq -r '.primary_node // ""' "$CLUSTER_INFO_FILE")
  generateTfvarsFromBootstrap || {
    error "Failed to regenerate terraform.tfvars"
    return 1
  }
  generatePackerVarsFromBootstrap || {
    error "Failed to regenerate packer.auto.pkrvars.hcl"
    return 1
  }
  return 0
}

# Re-run the Layer 2 (services) tfvars generator using current values
# from bootstrap.yml + vault credentials + cluster info. Skips silently
# if Vault hasn't been initialized yet (Layer 2 isn't deployable in
# that state, so refreshing its tfvars would just write garbage).
function refreshLayer2Configs() {
  ensureBootstrapComplete || return 1
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    return 0
  fi
  local NOMAD01_IP; NOMAD01_IP=$(getNomad01IP)
  if [ -z "$NOMAD01_IP" ]; then
    warn "Could not resolve nomad01 IP — skipping Layer 2 tfvars refresh"
    return 0
  fi
  writeServicesTfvars "$NOMAD01_IP" || {
    error "Failed to refresh terraform/services/terraform.tfvars"
    return 1
  }
  return 0
}

# Resolve nomad01's IP from bootstrap-generated tfvars (or compute from
# bootstrap.yml network.cidr as fallback). Replaces sed-grepping the
# vm-nomad module defaults, which were jdclabs-specific and have been
# removed.
function getNomad01IP() {
  local ip=""
  if [ -f "$SCRIPT_DIR/terraform/terraform.tfvars" ]; then
    ip=$(grep '"nomad01"' "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null \
         | sed -n 's/.*ip = "\([^"]*\)".*/\1/p' | head -1)
  fi
  if [ -z "$ip" ] && [ -f "$SCRIPT_DIR/bootstrap.yml" ] && command -v yq >/dev/null 2>&1; then
    local cidr; cidr=$(yq -r '.network.cidr // ""' "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)
    if [ -n "$cidr" ]; then
      local base; base=$(echo "$cidr" | cut -d/ -f1 | sed 's/\.[0-9]*$//')
      ip="${base}.14"
    fi
  fi
  echo "$ip"
}

# Switch every Proxmox node's primary DNS to the lab Pi-hole.
# Source of truth for the target IP is dns_primary_ipv4 in
# terraform/terraform.tfvars (BASE.4 by convention) — falls back to
# the deployed dns_main_nodes[0].
#
# This is the LAST step of a successful deploy. Done as the final
# action so a half-broken deploy never leaves Proxmox unable to
# resolve archive.ubuntu.com on the next bootstrap.
function setProxmoxDNSToLab() {
  ensureClusterContext || return 1
  local pihole_ip
  pihole_ip=$(sed -n 's/^dns_primary_ipv4.*=.*"\(.*\)"/\1/p' "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null | head -1)
  if [ -z "$pihole_ip" ]; then
    error "Cannot determine Pi-hole DNS IP from terraform.tfvars"
    return 1
  fi
  local search_domain
  search_domain=$(yamlGet dns_suffix 2>/dev/null || jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)

  doing "Switching Proxmox host DNS → ${pihole_ip} (lab Pi-hole)..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  ${node} (${ip}): dns1=${pihole_ip} search=${search_domain}"
    sshRun "$REMOTE_USER" "$ip" \
      "pvesh set /nodes/${node}/dns -dns1 ${pihole_ip} -search ${search_domain}" 2>/dev/null \
      || warn "    failed on ${node}"
  done
  success "Proxmox DNS pointed at lab Pi-hole"
}

# Reverse of setProxmoxDNSToLab — used when tearing down or
# diagnosing. Sets DNS back to the bootstrap.yml network.dns value
# (which falls back to network.gateway).
function revertProxmoxDNSToBootstrap() {
  ensureClusterContext || return 1
  _bootstrap_init_vars 2>/dev/null || true
  readBootstrapConfig || return 1
  local target="${NETWORK_DNS:-$NETWORK_GATEWAY}"
  if [ -z "$target" ]; then
    error "bootstrap.yml has neither network.dns nor network.gateway"
    return 1
  fi

  doing "Reverting Proxmox host DNS → ${target} (from bootstrap.yml)..."
  for i in "${!CLUSTER_NODES[@]}"; do
    local node="${CLUSTER_NODES[$i]}"
    local ip="${CLUSTER_NODE_IPS[$i]}"
    info "  ${node} (${ip}): dns1=${target}"
    sshRun "$REMOTE_USER" "$ip" \
      "pvesh set /nodes/${node}/dns -dns1 ${target}" 2>/dev/null \
      || warn "    failed on ${node}"
  done
  success "Proxmox DNS reverted to ${target}"
}

# Helper: list all Nomad VM IPs from the bootstrap-generated tfvars.
function _nomadVMIPs() {
  awk '/nomad_vm_configs/,/^}/' "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null \
    | grep -oE '"nomad[0-9]+".*ip = "[^"]+"' \
    | grep -oE 'ip = "[^"]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

# Switch every Nomad VM's resolver to the lab Pi-hole. Uses
# `resolvectl dns eth0` which is RUNTIME ONLY — a reboot reverts to
# the bootstrap-time DNS from cloud-init. That's a feature, not a bug:
# if a deploy goes sideways and the Pi-hole becomes unreachable, a
# reboot of the affected VM gets you back to a working resolver.
#
# Also restarts Docker so its DNS cache picks up the new resolver
# (Docker reads /etc/resolv.conf at daemon start; without a restart,
# new container pulls keep using the stale upstream).
#
# This is the LAST mid-deploy step before setProxmoxDNSToLab. Same
# rationale: never switch Nomad VMs to Pi-hole until every nomad_job
# that pulls images has succeeded.
function setNomadVMDNSToLab() {
  local pihole_ip
  pihole_ip=$(sed -n 's/^dns_primary_ipv4.*=.*"\(.*\)"/\1/p' "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null | head -1)
  if [ -z "$pihole_ip" ]; then
    error "Cannot determine Pi-hole DNS IP from terraform.tfvars"
    return 1
  fi
  local search_domain
  search_domain=$(yamlGet dns_suffix 2>/dev/null || jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)
  local key="$SCRIPT_DIR/crypto/labadmin"

  doing "Switching Nomad VM DNS → ${pihole_ip} (lab Pi-hole)..."
  for ip in $(_nomadVMIPs); do
    info "  ${ip}: dns=${pihole_ip} domain=${search_domain}"
    ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 labadmin@"$ip" "
      sudo resolvectl dns eth0 ${pihole_ip}
      sudo resolvectl domain eth0 ${search_domain}
      sudo resolvectl flush-caches
      sudo systemctl restart docker
    " 2>/dev/null || warn "    failed on ${ip}"
  done
  success "Nomad VM DNS pointed at lab Pi-hole"
}

# Reverse of setNomadVMDNSToLab. Resets to network.dns from
# bootstrap.yml (or network.gateway).
function revertNomadVMDNSToBootstrap() {
  _bootstrap_init_vars 2>/dev/null || true
  readBootstrapConfig || return 1
  local target="${NETWORK_DNS:-$NETWORK_GATEWAY}"
  if [ -z "$target" ]; then
    error "bootstrap.yml has neither network.dns nor network.gateway"
    return 1
  fi
  local key="$SCRIPT_DIR/crypto/labadmin"

  doing "Reverting Nomad VM DNS → ${target} (from bootstrap.yml)..."
  for ip in $(_nomadVMIPs); do
    info "  ${ip}: dns=${target}"
    ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 labadmin@"$ip" "
      sudo resolvectl dns eth0 ${target}
      sudo resolvectl domain eth0 ''
      sudo resolvectl flush-caches
      sudo systemctl restart docker
    " 2>/dev/null || warn "    failed on ${ip}"
  done
  success "Nomad VM DNS reverted to ${target}"
}

# Download the internal root CA cert from Vault's unauthenticated PKI
# endpoint and save it to crypto/. The cert is public material — no
# auth required, works even if Vault is sealed (the listener doesn't
# gate this path). Used for installing in browser/system trust stores
# so https://*.<dns_postfix> stops throwing self-signed warnings.
function downloadRootCA() {
  ensureClusterContext 2>/dev/null || true
  local dns_postfix
  dns_postfix=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)
  if [ -z "$dns_postfix" ]; then
    error "dns_postfix not found in cluster-info.json — has the cluster been deployed?"
    return 1
  fi

  local url="https://vault.${dns_postfix}/v1/pki/ca/pem"
  local out="$CRYPTO_DIR/proxmox-lab-root-ca.crt"

  doing "Downloading root CA from $url..."
  if ! curl -sk --max-time 10 -f "$url" -o "$out"; then
    rm -f "$out"
    error "Failed to fetch CA cert"
    info  "  Possible causes:"
    info  "    - Vault not yet deployed or unreachable"
    info  "    - DNS doesn't resolve vault.${dns_postfix} from this host"
    info  "      (try direct: curl -sk https://<nomad01-ip>:8200/v1/pki/ca/pem)"
    return 1
  fi

  if [ ! -s "$out" ] || ! head -1 "$out" | grep -q "BEGIN CERTIFICATE"; then
    rm -f "$out"
    error "Downloaded content isn't a PEM cert (Vault returned an error page?)"
    return 1
  fi

  success "Saved to: $out"
  if command -v openssl >/dev/null 2>&1; then
    info "  Subject:   $(openssl x509 -in "$out" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    info "  Not After: $(openssl x509 -in "$out" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  fi
  echo
  info "Install on this workstation:"
  info "  Linux/Fedora:  sudo cp $out /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust"
  info "  Linux/Debian:  sudo cp $out /usr/local/share/ca-certificates/proxmox-lab-root-ca.crt && sudo update-ca-certificates"
  info "  macOS:         sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $out"
  info "  Windows:       certutil -addstore -f \"ROOT\" $out  (run as Administrator)"
}

# Purge an existing AD join from one or more TrueNAS hosts. Reads the
# nas_servers block from bootstrap.yml and, for every entry with
# type=truenas, disables the directory service and clears the kerberos
# realm via the TrueNAS REST API. Intended for use *before* re-joining
# a TrueNAS that's still bound to a previous lab's AD (where the old
# DCs may be gone, so a graceful "leave with creds" isn't possible).
# Synology entries are listed but skipped — leave path differs there.
function truenasLeaveAD() {
  if ! command -v yq >/dev/null 2>&1; then
    error "yq is required to read bootstrap.yml"
    return 1
  fi
  if [ ! -f "$SCRIPT_DIR/bootstrap.yml" ]; then
    error "bootstrap.yml not found"
    return 1
  fi

  local count
  count=$(yq -r '.nas_servers | length // 0' "$SCRIPT_DIR/bootstrap.yml" 2>/dev/null)
  if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" = "0" ]; then
    error "No nas_servers configured in bootstrap.yml"
    info "  Add a nas_servers block (see bootstrap.yml.example) and retry"
    return 1
  fi

  local i name type addr api_key
  for i in $(seq 0 $((count - 1))); do
    name=$(yq -r ".nas_servers[$i].name // \"\"" "$SCRIPT_DIR/bootstrap.yml")
    type=$(yq -r ".nas_servers[$i].type // \"\"" "$SCRIPT_DIR/bootstrap.yml")
    addr=$(yq -r ".nas_servers[$i].address // \"\"" "$SCRIPT_DIR/bootstrap.yml")
    api_key=$(yq -r ".nas_servers[$i].api_key // \"\"" "$SCRIPT_DIR/bootstrap.yml")

    if [ "$type" != "truenas" ]; then
      info "Skipping $name ($type) — purge supported for TrueNAS only"
      continue
    fi
    if [ -z "$addr" ] || [ -z "$api_key" ]; then
      warn "$name: missing address or api_key — skipping"
      continue
    fi

    local api="https://$addr/api/v2.0"
    doing "Checking AD state on $name ($addr)..."

    local state enabled domain
    state=$(curl -sk --connect-timeout 10 --max-time 30 \
      -H "Authorization: Bearer $api_key" "$api/directoryservices" 2>/dev/null)
    if [ -z "$state" ] || echo "$state" | jq -e '.error' >/dev/null 2>&1; then
      error "  Cannot reach TrueNAS API at $addr (check address + api_key)"
      continue
    fi
    enabled=$(echo "$state" | jq -r 'if (.service_type == "ACTIVEDIRECTORY" and .enable == true) then "true" else "false" end')
    domain=$(echo "$state" | jq -r '.configuration.domain // .domainname // "unknown"')

    if [ "$enabled" != "true" ]; then
      success "  $name: not currently joined to AD (nothing to purge)"
      continue
    fi

    warn "  $name is currently joined to AD: $domain"
    read -rp "$(question "  Purge this AD config? [yes/NO]: ")" confirm
    if [ "$confirm" != "yes" ]; then
      info "  Skipped $name"
      continue
    fi

    doing "  Disabling AD on $name..."
    local resp
    resp=$(curl -sk -X PUT -H "Authorization: Bearer $api_key" -H "Content-Type: application/json" \
      "$api/directoryservices" -d '{"enable": false}' 2>/dev/null)
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      error "  Disable failed: $(echo "$resp" | jq -r '.error // .message // .')"
      continue
    fi

    doing "  Clearing kerberos realms..."
    local realms realm_id
    realms=$(curl -sk -H "Authorization: Bearer $api_key" "$api/kerberos/realm" 2>/dev/null)
    if echo "$realms" | jq -e '. | type == "array"' >/dev/null 2>&1; then
      for realm_id in $(echo "$realms" | jq -r '.[].id'); do
        curl -sk -X DELETE -H "Authorization: Bearer $api_key" \
          "$api/kerberos/realm/id/$realm_id" >/dev/null 2>&1 \
          || warn "    Failed to delete realm id=$realm_id"
      done
    fi

    success "  $name: AD purged ($domain). Reboot the NAS or restart 'middlewared' if rejoin misbehaves."
  done
}

# Apply a specific Layer 2 service target
function deployService() {
  local target="$1"
  local var_flag="${2:-}"

  ensureBootstrapComplete || return 1

  if [ ! -f "$SCRIPT_DIR/terraform/services/terraform.tfvars" ]; then
    error "Layer 2 not configured. Run 'Deploy all' (option 1) first, or init Vault manually."
    return 1
  fi

  doing "Deploying $target..."
  if [ -n "$var_flag" ]; then
    tf-services apply -auto-approve -var "$var_flag"
  else
    tf-services apply -auto-approve -target="$target"
  fi
}

# Toggle HA — reads settings from bootstrap.yml, writes to terraform.tfvars, applies Layer 1
function toggleHA() {
  ensureBootstrapComplete || return 1

  # Read HA settings from bootstrap.yml
  _bootstrap_init_vars 2>/dev/null || true

  local dns_ha_enabled dns_ha_vip dns_ha_router_id dns_ha_password
  local traefik_ha_enabled traefik_ha_vip traefik_ha_router_id traefik_ha_password

  dns_ha_enabled=$(yamlGet "ha_dns_enabled" 2>/dev/null || echo "false")
  dns_ha_vip=$(yamlGet "ha_dns_vip" 2>/dev/null || echo "")
  dns_ha_router_id=$(yamlGet "ha_dns_vrrp_router_id" 2>/dev/null || echo "51")
  dns_ha_password=$(yamlGet "ha_dns_vrrp_password" 2>/dev/null || echo "pihole-ha")

  traefik_ha_enabled=$(yamlGet "ha_traefik_enabled" 2>/dev/null || echo "false")
  traefik_ha_vip=$(yamlGet "ha_traefik_vip" 2>/dev/null || echo "")
  traefik_ha_router_id=$(yamlGet "ha_traefik_vrrp_router_id" 2>/dev/null || echo "53")
  traefik_ha_password=$(yamlGet "ha_traefik_vrrp_password" 2>/dev/null || echo "traefik-ha")

  if [ "$dns_ha_enabled" != "true" ] && [ "$traefik_ha_enabled" != "true" ]; then
    error "No HA settings found in bootstrap.yml"
    info "Add ha.dns and/or ha.traefik sections to bootstrap.yml first"
    return 1
  fi

  local TFVARS="${SCRIPT_DIR}/terraform/terraform.tfvars"

  echo
  info "HA Configuration from bootstrap.yml:"
  if [ "$dns_ha_enabled" = "true" ]; then
    info "  DNS HA:     VIP=${dns_ha_vip} RouterID=${dns_ha_router_id}"
  else
    info "  DNS HA:     disabled"
  fi
  if [ "$traefik_ha_enabled" = "true" ]; then
    info "  Traefik HA: VIP=${traefik_ha_vip} RouterID=${traefik_ha_router_id}"
  else
    info "  Traefik HA: disabled"
  fi
  echo

  # Remove existing HA lines from tfvars
  sed -i.bak '/^enable_dns_ha_vip/d; /^dns_ha_vip/d; /^dns_ha_vrrp/d; /^nomad_traefik_ha/d' "$TFVARS"
  rm -f "$TFVARS.bak"

  # Write HA settings
  if [ "$dns_ha_enabled" = "true" ] && [ -n "$dns_ha_vip" ]; then
    cat >> "$TFVARS" <<EOF

# DNS HA (keepalived VIP)
enable_dns_ha_vip      = true
dns_ha_vip_address     = "${dns_ha_vip}"
dns_ha_vrrp_router_id  = ${dns_ha_router_id}
dns_ha_vrrp_password   = "${dns_ha_password}"
EOF
  fi

  if [ "$traefik_ha_enabled" = "true" ] && [ -n "$traefik_ha_vip" ]; then
    cat >> "$TFVARS" <<EOF

# Traefik HA (keepalived VIP)
nomad_traefik_ha_enabled        = true
nomad_traefik_ha_vip            = "${traefik_ha_vip}"
nomad_traefik_ha_vrrp_router_id = ${traefik_ha_router_id}
nomad_traefik_ha_vrrp_password  = "${traefik_ha_password}"
EOF
  fi

  success "HA settings written to terraform.tfvars"

  # Get nomad address for apply
  local NOMAD01_IP
  NOMAD01_IP=$(getNomad01IP)
  if [ -z "$NOMAD01_IP" ]; then
    error "Cannot determine nomad01 IP — bootstrap may not have run yet"
    return 1
  fi

  doing "Applying HA configuration (Layer 1)..."
  tf apply -auto-approve -var "nomad_address=http://${NOMAD01_IP}:4646"
  success "HA configuration applied"

  # Update Layer 2 tfvars with VIP addresses for DNS records
  local SERVICES_TFVARS="${SCRIPT_DIR}/terraform/services/terraform.tfvars"
  if [ -f "$SERVICES_TFVARS" ]; then
    sed -i.bak "s|^traefik_ha_vip.*|traefik_ha_vip = \"${traefik_ha_vip}\"|" "$SERVICES_TFVARS"
    sed -i.bak "s|^dns_ha_vip.*|dns_ha_vip     = \"${dns_ha_vip}\"|" "$SERVICES_TFVARS"
    rm -f "$SERVICES_TFVARS.bak"

    doing "Updating DNS records with VIP addresses (Layer 2)..."
    tf-services apply -auto-approve
    success "DNS records updated with HA VIPs"
  fi
}

# Enable a service toggle and apply Layer 2
function enableService() {
  local service_name="$1"
  local var_name="deploy_${service_name}"
  local tfvars="$SCRIPT_DIR/terraform/services/terraform.tfvars"

  ensureBootstrapComplete || return 1

  if [ ! -f "$tfvars" ]; then
    error "Layer 2 not configured. Run 'Deploy all' (option 1) first."
    return 1
  fi

  # Re-sync Layer 2 tfvars from bootstrap.yml so passthrough fields
  # (unifi_*, profile_*, nas_servers, etc.) reflect any edits the
  # user made since the initial deploy. Preserves configure_* toggles
  # and netbox_api_token internally.
  refreshLayer2Configs || warn "Could not refresh Layer 2 tfvars — using existing values"

  # Add or update the deploy toggle in tfvars
  if grep -q "^${var_name}" "$tfvars"; then
    sed -i.bak "s/^${var_name}.*/${var_name} = true/" "$tfvars"
    rm -f "$tfvars.bak"
  else
    echo "${var_name} = true" >> "$tfvars"
  fi

  # Two-phase services: deploy job first, configure after healthy
  if [ "$service_name" = "authentik" ]; then
    if grep -q "^configure_authentik" "$tfvars"; then
      sed -i.bak "s/^configure_authentik.*/configure_authentik = false/" "$tfvars"
      rm -f "$tfvars.bak"
    else
      echo "configure_authentik = false" >> "$tfvars"
    fi
  fi

  if [ "$service_name" = "netbox" ]; then
    if grep -q "^configure_netbox" "$tfvars"; then
      sed -i.bak "s/^configure_netbox.*/configure_netbox = false/" "$tfvars"
      rm -f "$tfvars.bak"
    else
      echo "configure_netbox = false" >> "$tfvars"
    fi
  fi

  doing "Enabling $service_name..."
  tf-services apply -auto-approve

  # Authentik: second apply to configure apps/providers after it's running
  if [ "$service_name" = "authentik" ]; then
    doing "Waiting for Authentik to start..."
    local NOMAD01_IP
    NOMAD01_IP=$(getNomad01IP)
    for i in {1..30}; do
      if curl -sk --connect-timeout 3 "https://${NOMAD01_IP}:9443/-/health/live/" >/dev/null 2>&1; then
        success "Authentik is healthy"
        break
      fi
      sleep 10
    done

    local VAULT_ADDR ROOT_TOKEN API_TOKEN
    VAULT_ADDR=$(jq -r '.vault_address' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
    ROOT_TOKEN=$(jq -r '.root_token' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
    API_TOKEN=$(curl -sk -H "X-Vault-Token: $ROOT_TOKEN" "$VAULT_ADDR/v1/secret/data/authentik" 2>/dev/null | jq -r '.data.data.api_token // "not-configured"')

    sed -i.bak "s/^authentik_api_token.*/authentik_api_token = \"${API_TOKEN}\"/" "$tfvars"
    sed -i.bak "s/^configure_authentik.*/configure_authentik = true/" "$tfvars"
    rm -f "$tfvars.bak"
    if ! grep -q "^configure_authentik" "$tfvars"; then
      echo "configure_authentik = true" >> "$tfvars"
    fi

    doing "Configuring Authentik applications and providers..."
    tf-services apply -auto-approve
    success "Authentik configured"

    # Sync akadmin password — bootstrap password only applies on first DB init
    doing "Syncing Authentik admin password with Vault..."
    local ADMIN_PW
    ADMIN_PW=$(curl -sk -H "X-Vault-Token: $ROOT_TOKEN" "$VAULT_ADDR/v1/secret/data/authentik" 2>/dev/null | jq -r '.data.data.admin_password // empty')
    if [ -n "$API_TOKEN" ] && [ "$API_TOKEN" != "not-configured" ] && [ -n "$ADMIN_PW" ]; then
      local NOMAD01_IP_
      NOMAD01_IP_=$(getNomad01IP)
      local ADMIN_PK
      ADMIN_PK=$(curl -sk -H "Authorization: Bearer $API_TOKEN" "https://${NOMAD01_IP_}:9443/api/v3/core/users/?username=akadmin" 2>/dev/null | jq -r '.results[0].pk // empty')
      if [ -n "$ADMIN_PK" ]; then
        curl -sk -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
          -X POST "https://${NOMAD01_IP_}:9443/api/v3/core/users/$ADMIN_PK/set_password/" \
          -d "{\"password\":$(echo "$ADMIN_PW" | jq -Rs .)}" >/dev/null 2>&1
        success "Authentik admin password synced"
      fi
    fi
  fi

  # Netbox: second apply to populate inventory after it's running
  if [ "$service_name" = "netbox" ]; then
    doing "Waiting for Netbox to start..."
    local NOMAD01_IP
    NOMAD01_IP=$(getNomad01IP)
    for i in {1..30}; do
      if curl -sk --connect-timeout 3 "http://${NOMAD01_IP}:8080/login/" >/dev/null 2>&1; then
        success "Netbox is healthy"
        break
      fi
      sleep 10
    done

    local VAULT_ADDR ROOT_TOKEN NETBOX_TOKEN
    VAULT_ADDR=$(jq -r '.vault_address' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
    ROOT_TOKEN=$(jq -r '.root_token' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
    NETBOX_TOKEN=$(curl -sk -H "X-Vault-Token: $ROOT_TOKEN" "$VAULT_ADDR/v1/secret/data/netbox" 2>/dev/null | jq -r '.data.data.api_token // "not-configured"')

    sed -i.bak "s/^netbox_api_token.*/netbox_api_token = \"${NETBOX_TOKEN}\"/" "$tfvars"
    rm -f "$tfvars.bak"
    if ! grep -q "^netbox_api_token" "$tfvars"; then
      echo "netbox_api_token = \"${NETBOX_TOKEN}\"" >> "$tfvars"
    fi

    if grep -q "^configure_netbox" "$tfvars"; then
      sed -i.bak "s/^configure_netbox.*/configure_netbox = true/" "$tfvars"
      rm -f "$tfvars.bak"
    else
      echo "configure_netbox = true" >> "$tfvars"
    fi

    doing "Populating Netbox inventory..."
    tf-services apply -auto-approve
    success "Netbox configured and inventory populated"
  fi
}

# -----------------------------------------------------------------------------
# Main flow: deploy all services
# -----------------------------------------------------------------------------
function deployAll() {
  if [ ! -f "$SCRIPT_DIR/bootstrap.yml" ]; then
    error "bootstrap.yml not found."
    info "Copy bootstrap.yml.example to bootstrap.yml and edit it first."
    return 1
  fi

  checkRequirements
  generateSSHKeys

  # Read bootstrap.yml, discover cluster, create API token,
  # generate terraform.tfvars and packer.auto.pkrvars.hcl.
  runBootstrap || return 1

  # Set PROXMOX_HOST from bootstrap
  PROXMOX_HOST="$PROXMOX_IP"
  # SSH keys are now distributed inside runBootstrap (between
  # createAPIToken and downloadLXCTemplates) so the LXC template
  # download step can use key auth.

  cat <<EOF

############################################################################
Full Services Deployment

Phase 1: Build Packer templates (base + Docker/Nomad)
Phase 2: Deploy Nomad cluster + Vault container
Phase 3: Initialize Vault (init, unseal, save credentials)
Phase 4: Configure services (PKI, secrets, Traefik) + deploy DNS
############################################################################

EOF

  # ============================================
  # PHASE 1: Build Packer Templates
  # ============================================
  local TEMPLATES_EXIST=false
  if sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_DOCKER_TEMPLATE" &>/dev/null && \
     sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_NOMAD_TEMPLATE" &>/dev/null; then
    TEMPLATES_EXIST=true
  fi

  if [ "$TEMPLATES_EXIST" = "true" ]; then
    info "Skipping Packer build — templates already exist (9001, 9002)"
  else
    doing "Phase 1: Building Packer templates..."
    pressAnyKey
    docker compose build packer >/dev/null 2>&1
    docker compose run --rm -it packer init .

    # Build base Ubuntu (REQUIRED — Docker/Nomad templates clone from it)
    if ! sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config $VMID_BASE_TEMPLATE" &>/dev/null; then
      doing "Building base Ubuntu template (required)..."
      docker compose run --rm -it packer build -only='base-ubuntu.*' . || {
        error "Base Ubuntu template build failed — cannot continue"
        return 1
      }
      success "Base Ubuntu template built"
    else
      info "Base Ubuntu template $VMID_BASE_TEMPLATE already exists — skipping"
    fi

    # Build base Debian + Fedora (best-effort — used by other projects, not by deployAll).
    # Failures here don't block the rest of the deploy.
    if ! sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config 9997" &>/dev/null; then
      doing "Building base Debian template (best-effort)..."
      docker compose run --rm -it packer build -only='base-debian.*' . || warn "Debian base build failed — continuing"
    else
      info "Base Debian template 9997 already exists — skipping"
    fi
    if ! sshRun "$REMOTE_USER" "$PROXMOX_HOST" "qm config 9998" &>/dev/null; then
      doing "Building base Fedora template (best-effort)..."
      docker compose run --rm -it packer build -only='base-fedora.*' . || warn "Fedora base build failed — continuing"
    else
      info "Base Fedora template 9998 already exists — skipping"
    fi

    # Build Docker + Nomad templates (REQUIRED — clone from Ubuntu base)
    docker compose run --rm -it packer build -only='ubuntu-docker.*' -only='ubuntu-nomad.*' . || {
      error "Docker/Nomad template build failed — cannot continue"
      return 1
    }
    success "Phase 1 complete: Packer templates built"
  fi

  # ============================================
  # PHASE 2: Deploy Infrastructure (Layer 1)
  # ============================================
  cat <<EOF

############################################################################
Phase 2: Infrastructure Deployment

Deploying Nomad cluster, DNS, Kasm, and Vault container via Terraform.
############################################################################

EOF
  pressAnyKey

  # Resolve nomad01's IP from bootstrap-generated tfvars
  local NOMAD01_IP
  NOMAD01_IP=$(getNomad01IP)
  if [ -z "${NOMAD01_IP:-}" ]; then
    error "Cannot determine nomad01 IP — bootstrap may not have run yet"
    return 1
  fi

  doing "Initializing Terraform Layer 1..."
  tf init || { error "Terraform init failed"; return 1; }

  # Deploy Nomad cluster first — its provisioners install Nomad/Docker/etc.
  # via cloud-init, but Terraform only knows the VMs exist; it can't tell
  # that the Nomad API is actually serving on :4646 yet.
  doing "Deploying Nomad cluster (this may take several minutes)..."
  if ! tf apply -auto-approve \
    -var "nomad_address=http://${NOMAD01_IP}:4646" \
    -target=module.nomad; then
    error "Phase 2 failed: Nomad cluster apply"
    return 1
  fi
  success "Nomad cluster deployed"

  # Wait for the Nomad API to come up. Without this, the next tf apply
  # races cloud-init/systemd and gets connection-refused on :4646.
  doing "Waiting for Nomad API on http://${NOMAD01_IP}:4646..."
  local nomad_ready=false
  for i in {1..60}; do
    if curl -sf --connect-timeout 2 --max-time 3 "http://${NOMAD01_IP}:4646/v1/status/leader" >/dev/null 2>&1; then
      nomad_ready=true
      break
    fi
    sleep 5
  done
  if [ "$nomad_ready" != true ]; then
    error "Nomad API never came up on http://${NOMAD01_IP}:4646 after 5 minutes"
    info "  Check: ssh labadmin@${NOMAD01_IP} 'systemctl status nomad'"
    return 1
  fi
  success "Nomad API responding"

  # Now deploy the Vault Nomad job
  doing "Deploying Vault Nomad job..."
  if ! tf apply -auto-approve \
    -var "nomad_address=http://${NOMAD01_IP}:4646" \
    -target=null_resource.vault_directories \
    -target=nomad_job.vault; then
    error "Phase 2 failed: Vault job apply"
    return 1
  fi
  success "Phase 2 complete: Nomad cluster and Vault deployed"

  # ============================================
  # PHASE 3: Initialize Vault
  # ============================================
  cat <<EOF

############################################################################
Phase 3: Vault Initialization

Initializing and unsealing Vault. Credentials will be saved to
crypto/vault-credentials.json and Layer 2 tfvars will be generated.
############################################################################

EOF
  pressAnyKey

  # Wait for Vault to be reachable. First-run can take a couple minutes —
  # the alloc has to schedule, Docker pulls the vault image, the container
  # boots, and the GlusterFS sentinel guard waits for the brick to mount.
  doing "Waiting for Vault to be reachable (up to 5 min on first deploy — image pull)..."
  local vault_ready=false
  for i in {1..60}; do
    if curl -sk --connect-timeout 2 --max-time 3 "http://${NOMAD01_IP}:8200/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null 2>&1; then
      vault_ready=true
      break
    fi
    sleep 5
  done

  if [ "$vault_ready" != "true" ]; then
    error "Vault not reachable at http://${NOMAD01_IP}:8200 after 5 minutes"
    info "  Check allocation status:"
    info "    ssh labadmin@${NOMAD01_IP} 'nomad job status vault'"
    info "    ssh labadmin@${NOMAD01_IP} 'nomad alloc logs -job vault'"
    info "    ssh labadmin@${NOMAD01_IP} 'docker ps -a | grep vault'"
    return 1
  fi

  # Load cluster context for initAndUnsealVault
  loadClusterInfo 2>/dev/null || true
  DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)

  initAndUnsealVault "$NOMAD01_IP"
  # HA: peers (nomad02/03) come up sealed. Unseal them so they can
  # join the Raft cluster as voters.
  unsealAllVaults http || warn "Some Vault peers still sealed — see above"
  success "Phase 3 complete: Vault initialized + Raft peers unsealed"

  # ============================================
  # PHASE 4: Configure Services (Layer 2)
  # ============================================
  cat <<EOF

############################################################################
Phase 4: Service Configuration

Configuring Vault PKI, JWT auth, policies, secrets, and deploying
Traefik via Terraform Layer 2. Then deploying DNS and enabling
Vault TLS via Layer 1 (now with real Vault passwords).
############################################################################

EOF
  pressAnyKey

  # The DNS LXCs (Layer 1's module.dns-main) read secret/data/pihole
  # from Vault for admin/root passwords. That secret is created by
  # Layer 2's vault_kv_secret_v2.pihole. So Layer 2 secrets have to be
  # written first, THEN Layer 1 can deploy the DNS LXCs, THEN Layer 2
  # can push DNS records into them.
  doing "Initializing Terraform Layer 2..."
  tf-services init

  # Step 1: only the Vault scaffolding + service secrets. Use -target so
  # null_resource.pihole_dns_records (which SSHes to the not-yet-existent
  # LXC) doesn't fire here.
  doing "Layer 2 (step 1/2): Vault PKI, JWT auth, service secrets..."
  if ! tf-services apply -auto-approve \
    -target=vault_mount.pki \
    -target=vault_mount.pki_int \
    -target=vault_mount.secret \
    -target=vault_jwt_auth_backend.nomad \
    -target=vault_kv_secret_v2.pihole \
    -target=vault_kv_secret_v2.kasm \
    -target=vault_kv_secret_v2.packer \
    -target=vault_kv_secret_v2.ssh_keys \
    -target=vault_kv_secret_v2.cluster_config \
    -target=vault_kv_secret_v2.nomad_nodes; then
    error "Phase 4 failed: Layer 2 secrets apply"
    return 1
  fi
  success "Layer 2 secrets seeded"

  # Step 2: deploy DNS LXCs (Layer 1) — they can now read pihole creds from Vault.
  doing "Deploying DNS LXCs (Layer 1)..."
  if ! tf apply -auto-approve \
    -var "nomad_address=http://${NOMAD01_IP}:4646" \
    -target=module.dns-main; then
    error "Phase 4 failed: DNS LXC apply"
    return 1
  fi
  success "DNS LXCs deployed"

  # Step 3: full Layer 2 — Traefik, DNS records, everything else
  doing "Layer 2 (step 2/2): Traefik, DNS records, all remaining resources..."
  tf-services apply -auto-approve
  success "Layer 2 complete: Vault configured, Traefik deployed, DNS records pushed"

  # Final Layer 1 full apply: Vault TLS redeploy + any module.kasm if enabled.
  # No -target this time so any other Layer 1 resources catch up.
  doing "Enabling Vault TLS (Layer 1 full apply)..."
  tf apply -auto-approve -var "nomad_address=http://${NOMAD01_IP}:4646"

  # Vault seals on TLS redeploy — wait for it to come up, then unseal.
  # Both phases must succeed for downstream services (Authentik, Samba,
  # Netbox) to get their WIF tokens; if Vault stays sealed, every job
  # that has `vault {}` in its template fails to allocate with
  # "Vault is sealed" 503s.
  doing "Waiting for Vault to restart with TLS..."
  local vault_up=false
  sleep 5
  for i in {1..60}; do
    if curl -sk --connect-timeout 2 --max-time 5 \
         "https://${NOMAD01_IP}:8200/v1/sys/seal-status" >/dev/null 2>&1; then
      vault_up=true
      break
    fi
    sleep 2
  done
  if [ "$vault_up" != true ]; then
    error "Vault never came back up on https://${NOMAD01_IP}:8200 after TLS redeploy"
    info  "  Check: ssh labadmin@${NOMAD01_IP} 'nomad job status vault; nomad alloc logs -job vault | tail -30'"
    return 1
  fi

  # Unseal — verify it actually worked. The original code fired curl into
  # /dev/null and trusted it; if Vault was still loading data, the call
  # silently 503'd and Vault stayed sealed. Now we poll seal-status.
  local UNSEAL_KEY
  UNSEAL_KEY=$(jq -r '.unseal_key' "$VAULT_CREDENTIALS_FILE")
  if [ -z "$UNSEAL_KEY" ] || [ "$UNSEAL_KEY" = "null" ]; then
    error "Unseal key missing from $VAULT_CREDENTIALS_FILE"
    return 1
  fi

  doing "Unsealing Vault (TLS)..."
  # 12 attempts × ~5s = ~60s budget. iotvf.lab's Vault alloc takes
  # longer to settle after the TLS redeploy than jdclabs', and 5
  # attempts (25s) was bailing out before the listener was ready
  # to accept the unseal POST. Polling seal-status proves whether
  # we actually unsealed regardless of POST status, so a generous
  # budget is cheap.
  local unsealed=false
  local max_attempts=12
  for attempt in $(seq 1 $max_attempts); do
    curl -sk --max-time 10 -X PUT "https://${NOMAD01_IP}:8200/v1/sys/unseal" \
      -H "Content-Type: application/json" \
      -d "{\"key\": \"$UNSEAL_KEY\"}" >/dev/null 2>&1
    sleep 2
    # jq's `//` operator coalesces null OR false to the right side, so
    # `.sealed // true` returned "true" even when Vault was unsealed
    # (.sealed == false). Read the raw value and treat empty (failed
    # curl) as still-sealed explicitly.
    local sealed
    sealed=$(curl -sk --max-time 5 "https://${NOMAD01_IP}:8200/v1/sys/seal-status" 2>/dev/null \
              | jq -r '.sealed' 2>/dev/null)
    [ -z "$sealed" ] || [ "$sealed" = "null" ] && sealed="true"
    if [ "$sealed" = "false" ]; then
      unsealed=true
      break
    fi
    warn "  Vault still sealed after attempt ${attempt}/${max_attempts} — retrying..."
    sleep 3
  done
  if [ "$unsealed" != true ]; then
    error "Failed to unseal Vault after ${max_attempts} attempts"
    # One diagnostic retry — surface the actual response so we can tell
    # whether Vault is rejecting the key vs throwing 503 vs a TLS issue.
    info  "  Diagnostic POST response:"
    curl -sk --max-time 10 -w '\n  HTTP %{http_code}\n' -X PUT \
      "https://${NOMAD01_IP}:8200/v1/sys/unseal" \
      -H "Content-Type: application/json" \
      -d "{\"key\": \"$UNSEAL_KEY\"}" 2>&1 | sed 's/^/    /'
    info  "  Current seal-status:"
    curl -sk --max-time 5 "https://${NOMAD01_IP}:8200/v1/sys/seal-status" 2>&1 | sed 's/^/    /'
    info  "  Manual: curl -sk -X PUT https://${NOMAD01_IP}:8200/v1/sys/unseal \\"
    info  "                -H 'Content-Type: application/json' \\"
    info  "                -d '{\"key\":\"<unseal-key-from-crypto/vault-credentials.json>\"}'"
    return 1
  fi
  success "Vault unsealed on HTTPS"

  # HA: TLS rollover restarted every Vault container, so all 3 peers
  # are sealed. Unseal each so the Raft cluster comes back to a
  # healthy quorum.
  unsealAllVaults https || warn "Some Vault peers still sealed — see above"

  # Update credentials and Layer 2 tfvars with HTTPS address
  local tmp; tmp=$(mktemp)
  jq --arg addr "https://${NOMAD01_IP}:8200" '.vault_address = $addr' "$VAULT_CREDENTIALS_FILE" > "$tmp" && mv "$tmp" "$VAULT_CREDENTIALS_FILE"
  chmod 600 "$VAULT_CREDENTIALS_FILE"
  DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE" 2>/dev/null)
  initAndUnsealVault "$NOMAD01_IP"

  # Enable DNS records and Authentik for baseline deploy
  local SERVICES_TFVARS="${SCRIPT_DIR}/terraform/services/terraform.tfvars"

  # Enable DNS records
  if ! grep -q "deploy_dns_records" "$SERVICES_TFVARS" 2>/dev/null; then
    echo "deploy_dns_records = true" >> "$SERVICES_TFVARS"
  else
    sed -i.bak 's/deploy_dns_records.*/deploy_dns_records = true/' "$SERVICES_TFVARS"
    rm -f "$SERVICES_TFVARS.bak"
  fi

  # Wipe Authentik data if it exists from a previous deployment
  # (the DB has the old bootstrap token baked in, new Vault secrets won't match)
  doing "Cleaning stale Authentik data..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$ADMIN_KEY_PATH" "labadmin@${NOMAD01_IP}" \
    "sudo rm -rf /srv/gluster/nomad-data/authentik/postgres/* /srv/gluster/nomad-data/authentik/data/* 2>/dev/null" 2>/dev/null || true

  # Enable Authentik (phase 1: deploy job only, configure_authentik=false)
  if ! grep -q "deploy_authentik" "$SERVICES_TFVARS" 2>/dev/null; then
    echo "deploy_authentik = true" >> "$SERVICES_TFVARS"
  else
    sed -i.bak 's/deploy_authentik.*/deploy_authentik = true/' "$SERVICES_TFVARS"
    rm -f "$SERVICES_TFVARS.bak"
  fi
  if ! grep -q "configure_authentik" "$SERVICES_TFVARS" 2>/dev/null; then
    echo "configure_authentik = false" >> "$SERVICES_TFVARS"
  else
    sed -i.bak 's/configure_authentik.*/configure_authentik = false/' "$SERVICES_TFVARS"
    rm -f "$SERVICES_TFVARS.bak"
  fi

  # Re-apply Layer 2 with HTTPS Vault address + DNS records + Authentik job
  doing "Re-applying Layer 2 (HTTPS + DNS records + Authentik)..."
  tf-services apply -auto-approve

  # Authentik phase 2: wait for healthy, then configure apps/providers
  doing "Waiting for Authentik to start..."
  for i in {1..30}; do
    if curl -sk --connect-timeout 3 "https://${NOMAD01_IP}:9443/-/health/live/" >/dev/null 2>&1; then
      success "Authentik is healthy"
      break
    fi
    sleep 10
  done

  # Read API token from Vault and enable configuration
  local VAULT_ADDR_FINAL ROOT_TOKEN API_TOKEN
  VAULT_ADDR_FINAL=$(jq -r '.vault_address' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
  ROOT_TOKEN=$(jq -r '.root_token' "$VAULT_CREDENTIALS_FILE" 2>/dev/null)
  API_TOKEN=$(curl -sk -H "X-Vault-Token: $ROOT_TOKEN" "$VAULT_ADDR_FINAL/v1/secret/data/authentik" 2>/dev/null | jq -r '.data.data.api_token // "not-configured"')

  sed -i.bak "s/^authentik_api_token.*/authentik_api_token = \"${API_TOKEN}\"/" "$SERVICES_TFVARS"
  sed -i.bak "s/^configure_authentik.*/configure_authentik = true/" "$SERVICES_TFVARS"
  rm -f "$SERVICES_TFVARS.bak"

  doing "Configuring Authentik applications and providers..."
  tf-services apply -auto-approve
  success "Authentik configured"

  # Sync akadmin password — the bootstrap password only applies on first DB init.
  # If the DB persisted from a previous deployment, the password won't match Vault.
  doing "Syncing Authentik admin password with Vault..."
  local ADMIN_PW
  ADMIN_PW=$(curl -sk -H "X-Vault-Token: $ROOT_TOKEN" "$VAULT_ADDR_FINAL/v1/secret/data/authentik" 2>/dev/null | jq -r '.data.data.admin_password // empty')
  if [ -n "$API_TOKEN" ] && [ "$API_TOKEN" != "not-configured" ] && [ -n "$ADMIN_PW" ]; then
    local ADMIN_PK
    ADMIN_PK=$(curl -sk -H "Authorization: Bearer $API_TOKEN" "https://${NOMAD01_IP}:9443/api/v3/core/users/?username=akadmin" 2>/dev/null | jq -r '.results[0].pk // empty')
    if [ -n "$ADMIN_PK" ]; then
      curl -sk -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
        -X POST "https://${NOMAD01_IP}:9443/api/v3/core/users/$ADMIN_PK/set_password/" \
        -d "{\"password\":$(echo "$ADMIN_PW" | jq -Rs .)}" >/dev/null 2>&1
      success "Authentik admin password synced"
    fi
  fi

  # ABSOLUTE LAST STEPS: switch DNS over to the lab Pi-hole.
  # Order: Nomad VMs first, then Proxmox hosts. If anything earlier
  # fails, we never get here — leaving everything still able to
  # resolve archive.ubuntu.com / docker.io on the next retry.
  echo
  setNomadVMDNSToLab  || warn "Could not switch Nomad VM DNS — fix manually with menu d12"
  setProxmoxDNSToLab  || warn "Could not switch Proxmox DNS — fix manually with menu d12"

  echo
  success "Deployment complete!"
  echo
  info "Services:"
  info "  Vault:     https://${NOMAD01_IP}:8200"
  info "  Traefik:   http://${NOMAD01_IP}:8081"
  info "  Nomad:     http://${NOMAD01_IP}:4646"
  info "  Authentik: https://${NOMAD01_IP}:9443"
  echo
  info "To revert PVE DNS to your bootstrap network DNS (e.g. before purge): ./setup.sh --dev → d13"
  echo
}

# -----------------------------------------------------------------------------
# Bootstrap change detection
# -----------------------------------------------------------------------------
CONFIG_CHANGES_DETECTED=false
CONFIG_CHANGE_SUMMARY=""

function detectBootstrapChanges() {
  CONFIG_CHANGES_DETECTED=false
  CONFIG_CHANGE_SUMMARY=""

  # Only check if both files exist (deployed state)
  [ -f "$SCRIPT_DIR/bootstrap.yml" ] || return 0
  [ -f "$SCRIPT_DIR/terraform/terraform.tfvars" ] || return 0

  _bootstrap_init_vars 2>/dev/null || return 0

  local changes=()

  # --- HA settings ---
  local bs_dns_ha; bs_dns_ha=$(yamlGet ha_dns_enabled 2>/dev/null || echo "false")
  local bs_traefik_ha; bs_traefik_ha=$(yamlGet ha_traefik_enabled 2>/dev/null || echo "false")
  local tf_dns_ha; tf_dns_ha=$(grep -c "^enable_dns_ha_vip.*=.*true" "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null || echo "0")
  local tf_traefik_ha; tf_traefik_ha=$(grep -c "^nomad_traefik_ha_enabled.*=.*true" "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null || echo "0")

  if [ "$bs_dns_ha" = "true" ] && [ "$tf_dns_ha" = "0" ]; then
    changes+=("Enable DNS HA (VIP: $(yamlGet ha_dns_vip 2>/dev/null))")
  elif [ "$bs_dns_ha" != "true" ] && [ "$tf_dns_ha" != "0" ]; then
    changes+=("Disable DNS HA")
  fi

  if [ "$bs_traefik_ha" = "true" ] && [ "$tf_traefik_ha" = "0" ]; then
    changes+=("Enable Traefik HA (VIP: $(yamlGet ha_traefik_vip 2>/dev/null))")
  elif [ "$bs_traefik_ha" != "true" ] && [ "$tf_traefik_ha" != "0" ]; then
    changes+=("Disable Traefik HA")
  fi

  # --- Profile settings ---
  local bs_profile; bs_profile=$(yamlGet profile_server 2>/dev/null || true)
  if [ -f "$SCRIPT_DIR/terraform/services/terraform.tfvars" ]; then
    local tf_profile; tf_profile=$(sed -n 's/^profile_server.*=.*"\(.*\)"/\1/p' "$SCRIPT_DIR/terraform/services/terraform.tfvars" 2>/dev/null)
    if [ -n "$bs_profile" ] && [ "$bs_profile" != "$tf_profile" ]; then
      changes+=("Profile server: ${bs_profile}")
    fi
  fi

  # --- HA VIP address changes ---
  local bs_dns_vip; bs_dns_vip=$(yamlGet ha_dns_vip 2>/dev/null || true)
  local tf_dns_vip; tf_dns_vip=$(sed -n 's/^dns_ha_vip_address.*=.*"\(.*\)"/\1/p' "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null)
  if [ -n "$bs_dns_vip" ] && [ "$bs_dns_ha" = "true" ] && [ "$bs_dns_vip" != "$tf_dns_vip" ]; then
    changes+=("DNS VIP: ${tf_dns_vip:-none} → ${bs_dns_vip}")
  fi

  local bs_traefik_vip; bs_traefik_vip=$(yamlGet ha_traefik_vip 2>/dev/null || true)
  local tf_traefik_vip; tf_traefik_vip=$(sed -n 's/^nomad_traefik_ha_vip.*=.*"\(.*\)"/\1/p' "$SCRIPT_DIR/terraform/terraform.tfvars" 2>/dev/null)
  if [ -n "$bs_traefik_vip" ] && [ "$bs_traefik_ha" = "true" ] && [ "$bs_traefik_vip" != "$tf_traefik_vip" ]; then
    changes+=("Traefik VIP: ${tf_traefik_vip:-none} → ${bs_traefik_vip}")
  fi

  if [ ${#changes[@]} -gt 0 ]; then
    CONFIG_CHANGES_DETECTED=true
    CONFIG_CHANGE_SUMMARY=$(printf '    - %s\n' "${changes[@]}")
  fi
}

function applyConfigChanges() {
  info "Applying configuration changes from bootstrap.yml..."
  echo

  # Apply HA changes (reuses existing toggleHA logic)
  toggleHA

  # Update Layer 2 profile settings
  local SERVICES_TFVARS="${SCRIPT_DIR}/terraform/services/terraform.tfvars"
  if [ -f "$SERVICES_TFVARS" ]; then
    local bs_profile; bs_profile=$(yamlGet profile_server 2>/dev/null || true)
    local bs_share; bs_share=$(yamlGet profile_share 2>/dev/null || echo "profiles")
    local bs_drive; bs_drive=$(yamlGet profile_drive_letter 2>/dev/null || echo "P")

    sed -i.bak "s|^profile_server.*|profile_server       = \"${bs_profile}\"|" "$SERVICES_TFVARS"
    sed -i.bak "s|^profile_share.*|profile_share        = \"${bs_share}\"|" "$SERVICES_TFVARS"
    sed -i.bak "s|^profile_drive_letter.*|profile_drive_letter = \"${bs_drive}\"|" "$SERVICES_TFVARS"
    rm -f "$SERVICES_TFVARS.bak"

    doing "Applying Layer 2 changes..."
    tf-services apply -auto-approve
  fi

  CONFIG_CHANGES_DETECTED=false
  success "Configuration changes applied"
}

# -----------------------------------------------------------------------------
# Menu
# -----------------------------------------------------------------------------
function showMenu() {
  echo -e "${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo
  echo -e "  ${C_BOLD}Setup${C_RESET}"
  echo "    1) Deploy all services"
  echo "    2) Enable HA (keepalived VIPs)"
  echo
  echo -e "  ${C_BOLD}Optional Services${C_RESET}"
  echo "    3) Kasm Workspaces"
  echo "    4) Samba AD + LDAP Account Manager"
  echo "    5) Uptime Kuma (monitoring)"
  echo "    6) Netbox (inventory management)"
  echo "    7) Periodic backups (NFS/SMB)"
  echo "    8) Tailscale subnet routers"
  echo
  echo -e "  ${C_BOLD}Management${C_RESET}"
  echo "    9)  Rollback services (Layer 2)"
  echo "    10) Rollback infrastructure (Layer 1 + 2)"
  echo "    11) Purge entire deployment"
  echo "    0)  Exit"

  if [ "$DEV_MODE" = true ]; then
    echo
    echo -e "  ${C_DIM}─── Developer Tools ──────────────────────${C_RESET}"
    echo
    echo "   d1) Rebuild base templates (Ubuntu required; Debian + Fedora best-effort)"
    echo "   d2) Rebuild service templates (Docker, Nomad)"
    echo "   d3) Reset Proxmox user/token/role"
    echo "   d4) Deploy infrastructure (Nomad, Vault, DNS)"
    echo "   d5) Deploy services (Traefik, Authentik, secrets)"
    echo "   d6) Deploy Nomad cluster only"
    echo "   d7) Deploy DNS only"
    echo "   d8) Deploy Vault only"
    echo "   d9) Deploy Traefik only"
    echo "  d10) Deploy Authentik only"
    echo "  d11) Rebuild DNS records"
    echo "  d12) Switch ALL DNS → lab Pi-hole (Nomad VMs + PVE hosts; default last-step of deployAll)"
    echo "  d13) Revert ALL DNS → bootstrap.yml network.dns (Nomad VMs + PVE hosts)"
    echo "  d14) Download internal root CA cert (saves to crypto/proxmox-lab-root-ca.crt)"
    echo "  d15) TrueNAS — purge existing AD join (reads nas_servers from bootstrap.yml)"
  fi
  echo
}

header

# Detect bootstrap.yml changes on startup
detectBootstrapChanges

while true; do
  # Show config change alert if detected
  if [ "$CONFIG_CHANGES_DETECTED" = "true" ]; then
    echo
    echo -e "  ${C_BOLD}\033[1;33m⚠  Configuration changes detected in bootstrap.yml:${C_RESET}"
    echo "$CONFIG_CHANGE_SUMMARY"
    echo -e "    ${C_BOLD}*) Apply configuration changes${C_RESET}"
  fi

  showMenu
  if [ "$DEV_MODE" = true ]; then
    read -rp "$(question "Select [0-11, d1-d15]: ")" choice
  else
    read -rp "$(question "Select [0-11]: ")" choice
  fi

  case $choice in
    1)  deployAll;;
    2)  toggleHA;;

    # Optional services
    3)  ensureBootstrapComplete && refreshGeneratedConfigs && tf apply -auto-approve -var "deploy_kasm=true";;
    4)  enableService "samba_ad" && enableService "lam";;
    5)  enableService "uptime_kuma";;
    6)  enableService "netbox";;
    7)  enableService "backup";;
    8)  enableService "tailscale";;

    # Management
    9)   ensureBootstrapComplete && rollbackLayer2;;
    10)  ensureBootstrapComplete && rollbackLayer1;;
    11)  purgeDeployment;;

    # Developer tools
    d1|D1)   if [ "$DEV_MODE" = true ]; then docker compose build packer >/dev/null 2>&1 && docker compose run --rm -it packer init . && docker compose run --rm -it packer build -only='base-ubuntu.*' . && (docker compose run --rm -it packer build -only='base-debian.*' . || warn "Debian base build failed") && (docker compose run --rm -it packer build -only='base-fedora.*' . || warn "Fedora base build failed"); else error "Invalid option"; fi;;
    d2|D2)   if [ "$DEV_MODE" = true ]; then docker compose build packer >/dev/null 2>&1 && docker compose run --rm -it packer init . && docker compose run --rm -it packer build -only='ubuntu-docker.*' -only='ubuntu-nomad.*' .; else error "Invalid option"; fi;;
    d3|D3)   if [ "$DEV_MODE" = true ]; then resetProxmoxCredentials;                                      else error "Invalid option"; fi;;
    d4|D4)   if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf apply -auto-approve;             else error "Invalid option"; fi;;
    d5|D5)   if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf-services apply -auto-approve;    else error "Invalid option"; fi;;
    d6|D6)   if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf apply -auto-approve -target=module.nomad; else error "Invalid option"; fi;;
    d7|D7)   if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf apply -auto-approve -target=module.dns-main; else error "Invalid option"; fi;;
    d8|D8)   if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf apply -auto-approve -target=nomad_job.vault && initAndUnsealVault; else error "Invalid option"; fi;;
    d9|D9)   if [ "$DEV_MODE" = true ]; then enableService "traefik";                                      else error "Invalid option"; fi;;
    d10|D10) if [ "$DEV_MODE" = true ]; then enableService "authentik";                                    else error "Invalid option"; fi;;
    d11|D11) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && tf-services apply -auto-approve -target=null_resource.pihole_dns_records -target=null_resource.pihole_nebula_sync; else error "Invalid option"; fi;;
    d12|D12) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && ensureClusterContext && setNomadVMDNSToLab && setProxmoxDNSToLab; else error "Invalid option"; fi;;
    d13|D13) if [ "$DEV_MODE" = true ]; then ensureBootstrapComplete && ensureClusterContext && revertNomadVMDNSToBootstrap && revertProxmoxDNSToBootstrap; else error "Invalid option"; fi;;
    d14|D14) if [ "$DEV_MODE" = true ]; then downloadRootCA;                                                  else error "Invalid option"; fi;;
    d15|D15) if [ "$DEV_MODE" = true ]; then truenasLeaveAD;                                                  else error "Invalid option"; fi;;

    # Config change apply
    \*) if [ "$CONFIG_CHANGES_DETECTED" = "true" ]; then applyConfigChanges; else error "No changes detected"; fi;;

    0|q|Q) echo; info "Goodbye."; break;;
    *)     error "Invalid option: $choice";;
  esac

  # Skip pause if returning from submenu
  if [ "${SKIP_PAUSE:-false}" = "true" ]; then
    SKIP_PAUSE=false
  else
    echo
    read -rp "  Press Enter to continue..."
  fi
done
