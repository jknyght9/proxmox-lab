#!/usr/bin/env bash

# verify.sh - Post-deployment health verification
#
# Checks the health of all deployed infrastructure components:
#   - Nomad cluster (servers, leader, node eligibility)
#   - Vault (init, unseal, TLS, PKI, KV, JWT auth, ACME)
#   - Traefik (system job, ping, TLS cert chain, config)
#   - DNS (Pi-hole containers, resolution)
#   - GlusterFS (mount, sentinel)
#
# Usage:
#   source lib/verify.sh
#   verifyDeployment
#
# Globals read: SCRIPT_DIR, CRYPTO_DIR, CLUSTER_INFO_FILE,
#   VAULT_CREDENTIALS_FILE, ADMIN_KEY_PATH, ENTERPRISE_KEY_PATH

# Source SSH helpers if not already loaded
if ! declare -f sshRunAdmin >/dev/null 2>&1; then
  if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/util.sh" ]; then
    source "$SCRIPT_DIR/lib/util.sh"
  fi
fi

# Internal counters
_VERIFY_PASS=0
_VERIFY_FAIL=0

# Record a passing check
function _pass() {
  echo -e "  \033[0;32m[PASS]\033[0m $*"
  ((_VERIFY_PASS++)) || true
}

# Record a failing check
function _fail() {
  echo -e "  \033[0;31m[FAIL]\033[0m $*"
  ((_VERIFY_FAIL++)) || true
}

# Record a skipped check
function _skip() {
  echo -e "  \033[1;33m[SKIP]\033[0m $*"
}

# SSH to a Nomad VM (labadmin key)
function _vssh() {
  ssh -i "$ADMIN_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=10 "labadmin@$1" "$2" 2>/dev/null
}

# SSH to a Proxmox node (enterprise key)
function _vssh_pve() {
  ssh -i "$ENTERPRISE_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=10 "root@$1" "$2" 2>/dev/null
}

# ============================================================================
# verifyDeployment - Main verification function
# ============================================================================
function verifyDeployment() {
  _VERIFY_PASS=0
  _VERIFY_FAIL=0

  echo
  echo "========================================================================"
  echo "  Deployment Verification"
  echo "========================================================================"
  echo

  # --- Resolve IPs ---
  local NOMAD_IPS=()
  local NOMAD_HOSTNAMES=()
  local DNS_IPS=()
  local PVE_IPS=()

  # Nomad IPs from variables.tf defaults
  local vars_file="${SCRIPT_DIR}/terraform/vm-nomad/variables.tf"
  if [ -f "$vars_file" ]; then
    while IFS= read -r line; do
      local ip
      ip=$(echo "$line" | sed -n 's/.*ip = "\([^"]*\)".*/\1/p')
      local hostname
      hostname=$(echo "$line" | sed -n 's/.*"\(nomad[0-9]*\)".*/\1/p')
      if [ -n "$ip" ] && [ -n "$hostname" ]; then
        NOMAD_IPS+=("$ip")
        NOMAD_HOSTNAMES+=("$hostname")
      fi
    done < <(grep 'nomad0[0-9].*ip =' "$vars_file")
  fi

  # Fallback
  if [ ${#NOMAD_IPS[@]} -eq 0 ]; then
    NOMAD_IPS=("10.1.50.114" "10.1.50.115" "10.1.50.116")
    NOMAD_HOSTNAMES=("nomad01" "nomad02" "nomad03")
  fi

  # DNS IPs from hosts.json or hardcoded
  if [ -f "${SCRIPT_DIR}/hosts.json" ]; then
    while IFS= read -r ip; do
      DNS_IPS+=("$(echo "$ip" | cut -d'/' -f1)")
    done < <(jq -r '.external[] | select(.hostname | startswith("dns-")) | .ip' "${SCRIPT_DIR}/hosts.json" 2>/dev/null)
  fi
  if [ ${#DNS_IPS[@]} -eq 0 ]; then
    DNS_IPS=("10.1.50.4" "10.1.50.5" "10.1.50.6")
  fi

  # Proxmox IPs from cluster-info.json
  if [ -f "${CLUSTER_INFO_FILE:-}" ]; then
    while IFS= read -r ip; do
      PVE_IPS+=("$ip")
    done < <(jq -r '.nodes[].ip' "$CLUSTER_INFO_FILE" 2>/dev/null)
  fi
  if [ ${#PVE_IPS[@]} -eq 0 ]; then
    PVE_IPS=("10.1.50.210" "10.1.50.211" "10.1.50.212")
  fi

  # Vault credentials
  local VAULT_ADDR="" ROOT_TOKEN="" UNSEAL_KEY=""
  if [ -f "${VAULT_CREDENTIALS_FILE:-}" ]; then
    VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
    ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")
    UNSEAL_KEY=$(jq -r '.unseal_key // empty' "$VAULT_CREDENTIALS_FILE")
  fi

  # ========================================================================
  # 1. Nomad Cluster
  # ========================================================================
  echo "--- Nomad Cluster ---"

  local NOMAD01_IP="${NOMAD_IPS[0]}"

  # Check all 3 servers alive
  for i in "${!NOMAD_IPS[@]}"; do
    local ip="${NOMAD_IPS[$i]}"
    local hostname="${NOMAD_HOSTNAMES[$i]}"
    if curl -sf --connect-timeout 5 "http://${ip}:4646/v1/agent/self" >/dev/null 2>&1; then
      _pass "Nomad agent alive: ${hostname} (${ip})"
    else
      _fail "Nomad agent not reachable: ${hostname} (${ip})"
    fi
  done

  # Check leader elected
  local leader
  leader=$(curl -sf --connect-timeout 5 "http://${NOMAD01_IP}:4646/v1/status/leader" 2>/dev/null | tr -d '"')
  if [ -n "$leader" ] && [ "$leader" != "" ]; then
    _pass "Nomad leader elected: ${leader}"
  else
    _fail "No Nomad leader elected"
  fi

  # Check all 3 nodes eligible
  local nodes_json
  nodes_json=$(curl -sf --connect-timeout 5 "http://${NOMAD01_IP}:4646/v1/nodes" 2>/dev/null)
  if [ -n "$nodes_json" ]; then
    local eligible_count
    eligible_count=$(echo "$nodes_json" | jq '[.[] | select(.Status == "ready" and .SchedulingEligibility == "eligible")] | length' 2>/dev/null)
    if [ "${eligible_count:-0}" -ge 3 ]; then
      _pass "All ${eligible_count} Nomad nodes eligible"
    else
      _fail "Only ${eligible_count:-0}/3 Nomad nodes eligible"
    fi
  else
    _fail "Cannot query Nomad nodes API"
  fi

  echo

  # ========================================================================
  # 2. Vault
  # ========================================================================
  echo "--- Vault ---"

  if [ -z "$VAULT_ADDR" ]; then
    _fail "No vault_address in credentials file"
    echo
  else
    # Initialized and unsealed
    local vault_health
    vault_health=$(curl -skf --connect-timeout 5 "${VAULT_ADDR}/v1/sys/health" 2>/dev/null)
    if [ -n "$vault_health" ]; then
      local v_init v_sealed
      v_init=$(echo "$vault_health" | jq -r '.initialized')
      v_sealed=$(echo "$vault_health" | jq -r '.sealed')
      if [ "$v_init" = "true" ]; then
        _pass "Vault initialized"
      else
        _fail "Vault not initialized"
      fi
      if [ "$v_sealed" = "false" ]; then
        _pass "Vault unsealed"
      else
        _fail "Vault is sealed"
      fi
    else
      # Try with permissive codes
      local vault_any
      vault_any=$(curl -skf --connect-timeout 5 "${VAULT_ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" 2>/dev/null)
      if [ -n "$vault_any" ]; then
        _fail "Vault reachable but health check failed (may be sealed or uninitialized)"
      else
        _fail "Vault not reachable at ${VAULT_ADDR}"
      fi
    fi

    # HTTPS check
    if [[ "$VAULT_ADDR" == https://* ]]; then
      _pass "Vault serving HTTPS"
    else
      _fail "Vault not serving HTTPS (address: ${VAULT_ADDR})"
    fi

    # TLS cert chain validation
    local vault_host vault_port
    vault_host=$(echo "$VAULT_ADDR" | sed 's|https\?://||' | cut -d: -f1)
    vault_port=$(echo "$VAULT_ADDR" | sed 's|https\?://||' | cut -d: -f2)
    vault_port="${vault_port:-8200}"

    local root_ca_path="${SCRIPT_DIR}/crypto"
    local root_ca_file=""
    # Find root CA on disk (exported by Layer 2)
    if [ -f "${root_ca_path}/root_ca.crt" ]; then
      root_ca_file="${root_ca_path}/root_ca.crt"
    fi

    # Check cert chain via nomad01 (the cert lives on GlusterFS)
    if [[ "$VAULT_ADDR" == https://* ]]; then
      local cert_count
      cert_count=$(_vssh "$NOMAD01_IP" "echo | openssl s_client -connect ${vault_host}:${vault_port} -servername ${vault_host} 2>/dev/null | grep -c 'BEGIN CERTIFICATE'" 2>/dev/null)
      if [ "${cert_count:-0}" -ge 2 ]; then
        _pass "Vault TLS cert chain valid (${cert_count} certs: leaf + intermediate)"
      elif [ "${cert_count:-0}" -eq 1 ]; then
        _fail "Vault TLS has only leaf cert (missing intermediate)"
      else
        _fail "Cannot verify Vault TLS cert chain"
      fi
    fi

    # PKI mounts
    if [ -n "$ROOT_TOKEN" ]; then
      local mounts
      mounts=$(curl -skf -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/sys/mounts" 2>/dev/null)
      if [ -n "$mounts" ]; then
        if echo "$mounts" | jq -e '.data["pki/"]' >/dev/null 2>&1 || echo "$mounts" | jq -e '.["pki/"]' >/dev/null 2>&1; then
          _pass "PKI mount exists: pki/"
        else
          _fail "PKI mount missing: pki/"
        fi
        if echo "$mounts" | jq -e '.data["pki_int/"]' >/dev/null 2>&1 || echo "$mounts" | jq -e '.["pki_int/"]' >/dev/null 2>&1; then
          _pass "PKI mount exists: pki_int/"
        else
          _fail "PKI mount missing: pki_int/"
        fi
        if echo "$mounts" | jq -e '.data["secret/"]' >/dev/null 2>&1 || echo "$mounts" | jq -e '.["secret/"]' >/dev/null 2>&1; then
          _pass "KV mount exists: secret/"
        else
          _fail "KV mount missing: secret/"
        fi
      else
        _fail "Cannot query Vault mounts (auth issue?)"
      fi

      # JWT auth backend
      local auth_backends
      auth_backends=$(curl -skf -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/sys/auth" 2>/dev/null)
      if echo "$auth_backends" | jq -e '.data["jwt-nomad/"]' >/dev/null 2>&1 || echo "$auth_backends" | jq -e '.["jwt-nomad/"]' >/dev/null 2>&1; then
        _pass "JWT auth backend exists: jwt-nomad"
      else
        _fail "JWT auth backend missing: jwt-nomad"
      fi

      # ACME on pki_int
      local acme_config
      acme_config=$(curl -skf -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/pki_int/config/cluster" 2>/dev/null)
      if [ -n "$acme_config" ]; then
        # Check if ACME headers are configured (indicates ACME is set up)
        local acme_path
        acme_path=$(curl -skf -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/pki_int/config/acme" 2>/dev/null)
        if echo "$acme_path" | jq -e '.data.enabled == true' >/dev/null 2>&1; then
          _pass "ACME enabled on pki_int"
        else
          _skip "ACME not enabled on pki_int (may not be configured)"
        fi
      else
        _skip "Cannot check ACME config on pki_int"
      fi

      # Root CA consistency: compare Vault root CA with what's on Nomad nodes
      local vault_root_ca
      vault_root_ca=$(curl -skf -H "X-Vault-Token: ${ROOT_TOKEN}" "${VAULT_ADDR}/v1/pki/ca/pem" 2>/dev/null | openssl x509 -fingerprint -noout 2>/dev/null)
      if [ -n "$vault_root_ca" ]; then
        local node_root_ca
        node_root_ca=$(_vssh "$NOMAD01_IP" "cat /usr/local/share/ca-certificates/proxmox-lab*.crt 2>/dev/null | openssl x509 -fingerprint -noout 2>/dev/null" 2>/dev/null)
        if [ -n "$node_root_ca" ] && [ "$vault_root_ca" = "$node_root_ca" ]; then
          _pass "Root CA on nomad01 matches Vault root CA"
        elif [ -z "$node_root_ca" ]; then
          _fail "Root CA not found on nomad01 trust store"
        else
          _fail "Root CA mismatch: Vault vs nomad01"
        fi
      else
        _fail "Cannot fetch root CA from Vault PKI"
      fi
    else
      _skip "No root token — skipping Vault mount/auth checks"
    fi

    echo
  fi

  # ========================================================================
  # 3. Traefik
  # ========================================================================
  echo "--- Traefik ---"

  # Check Traefik running on all Nomad nodes (system job)
  local traefik_allocs
  traefik_allocs=$(curl -sf --connect-timeout 5 "http://${NOMAD01_IP}:4646/v1/job/traefik/allocations" 2>/dev/null)
  if [ -n "$traefik_allocs" ]; then
    local running_count
    running_count=$(echo "$traefik_allocs" | jq '[.[] | select(.ClientStatus == "running")] | length' 2>/dev/null)
    if [ "${running_count:-0}" -ge 3 ]; then
      _pass "Traefik running on all ${running_count} Nomad nodes (system job)"
    elif [ "${running_count:-0}" -ge 1 ]; then
      _fail "Traefik running on only ${running_count}/3 nodes"
    else
      _fail "No running Traefik allocations"
    fi
  else
    _fail "Cannot query Traefik job allocations"
  fi

  # Check Traefik /ping on each node
  for i in "${!NOMAD_IPS[@]}"; do
    local ip="${NOMAD_IPS[$i]}"
    local hostname="${NOMAD_HOSTNAMES[$i]}"
    if curl -sf --connect-timeout 5 "http://${ip}:8081/ping" >/dev/null 2>&1; then
      _pass "Traefik /ping responds: ${hostname}"
    else
      _fail "Traefik /ping failed: ${hostname}"
    fi
  done

  # TLS cert exists
  local cert_exists
  cert_exists=$(_vssh "$NOMAD01_IP" "test -f /srv/gluster/nomad-data/traefik/tls/cert.pem && echo yes || echo no")
  if [ "$cert_exists" = "yes" ]; then
    _pass "Traefik TLS cert exists at /srv/gluster/nomad-data/traefik/tls/cert.pem"
  else
    _fail "Traefik TLS cert missing"
  fi

  # Traefik cert chain (leaf + intermediate)
  local traefik_cert_count
  traefik_cert_count=$(_vssh "$NOMAD01_IP" "grep -c 'BEGIN CERTIFICATE' /srv/gluster/nomad-data/traefik/tls/cert.pem 2>/dev/null")
  if [ "${traefik_cert_count:-0}" -ge 2 ]; then
    _pass "Traefik cert chain valid (${traefik_cert_count} certs: leaf + intermediate)"
  elif [ "${traefik_cert_count:-0}" -eq 1 ]; then
    _fail "Traefik cert has only leaf (missing ca_chain)"
  else
    _skip "Cannot check Traefik cert chain"
  fi

  # tls.yml config
  local tls_yml_exists
  tls_yml_exists=$(_vssh "$NOMAD01_IP" "test -f /srv/gluster/nomad-data/traefik/config/tls.yml && echo yes || echo no")
  if [ "$tls_yml_exists" = "yes" ]; then
    _pass "Traefik tls.yml config exists"
  else
    _fail "Traefik tls.yml config missing"
  fi

  echo

  # ========================================================================
  # 4. DNS
  # ========================================================================
  echo "--- DNS (Pi-hole) ---"

  # Check Pi-hole containers running (VMIDs 910-912)
  local dns_vmids=(910 911 912)
  for j in "${!dns_vmids[@]}"; do
    local vmid="${dns_vmids[$j]}"
    local dns_ip="${DNS_IPS[$j]:-}"
    local container_status=""

    # Check via Proxmox API (pct status)
    for pve_ip in "${PVE_IPS[@]}"; do
      container_status=$(_vssh_pve "$pve_ip" "pct status $vmid 2>/dev/null" 2>/dev/null)
      if [ -n "$container_status" ]; then
        break
      fi
    done

    if echo "$container_status" | grep -q "running" 2>/dev/null; then
      _pass "Pi-hole container running: VMID ${vmid}"
    else
      _fail "Pi-hole container not running: VMID ${vmid} (status: ${container_status:-unknown})"
    fi
  done

  # DNS resolution test
  for j in "${!DNS_IPS[@]}"; do
    local dns_ip="${DNS_IPS[$j]}"
    local dig_result
    dig_result=$(dig +short +time=3 +tries=1 @"${dns_ip}" google.com 2>/dev/null)
    if [ -n "$dig_result" ]; then
      _pass "DNS resolution works: @${dns_ip} google.com -> ${dig_result}"
    else
      _fail "DNS resolution failed: @${dns_ip} google.com"
    fi
  done

  echo

  # ========================================================================
  # 5. GlusterFS
  # ========================================================================
  echo "--- GlusterFS ---"

  for i in "${!NOMAD_IPS[@]}"; do
    local ip="${NOMAD_IPS[$i]}"
    local hostname="${NOMAD_HOSTNAMES[$i]}"

    # Check mount
    local mount_check
    mount_check=$(_vssh "$ip" "mountpoint -q /srv/gluster/nomad-data && echo mounted || echo not_mounted")
    if [ "$mount_check" = "mounted" ]; then
      _pass "GlusterFS mounted on ${hostname}: /srv/gluster/nomad-data"
    else
      _fail "GlusterFS NOT mounted on ${hostname}"
    fi
  done

  # Sentinel file check
  local sentinel_check
  sentinel_check=$(_vssh "$NOMAD01_IP" "test -d /srv/gluster/nomad-data/vault && echo yes || echo no")
  if [ "$sentinel_check" = "yes" ]; then
    _pass "GlusterFS sentinel directory exists (vault/)"
  else
    _fail "GlusterFS sentinel directory missing"
  fi

  echo

  # ========================================================================
  # Summary
  # ========================================================================
  echo "========================================================================"
  local total=$((_VERIFY_PASS + _VERIFY_FAIL))
  if [ "$_VERIFY_FAIL" -eq 0 ]; then
    echo -e "  \033[0;32mAll ${total} checks passed.\033[0m"
  else
    echo -e "  \033[0;31m${_VERIFY_FAIL} of ${total} checks failed.\033[0m"
  fi
  echo "========================================================================"
  echo

  if [ "$_VERIFY_FAIL" -gt 0 ]; then
    return 1
  fi
  return 0
}
