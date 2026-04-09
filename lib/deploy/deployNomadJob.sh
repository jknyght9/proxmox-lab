#!/usr/bin/env bash

# Generic function for deploying Nomad jobs
# Parameters: job_name, job_file, [storage_path], [extra_run_args]
#   extra_run_args: additional args passed to `nomad job run`, e.g. "-var foo=bar"
function deployNomadJob() {
  local job_name="$1"
  local job_file="$2"
  local storage_path="${3:-}"
  local extra_run_args="${4:-}"

  ensureClusterContext || return 1

  # Get first Nomad node IP from hosts.json
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  if [ -z "$NOMAD_IP" ] || [ "$NOMAD_IP" = "null" ]; then
    error "No Nomad nodes found in hosts.json. Deploy Nomad first (option 5)."
    return 1
  fi

  if [ ! -f "$job_file" ]; then
    error "Job file not found: $job_file"
    return 1
  fi

  doing "Deploying $job_name to Nomad cluster..."

  # Create storage directory if specified
  if [ -n "$storage_path" ]; then
    sshRunAdmin "$VM_USER" "$NOMAD_IP" "sudo mkdir -p $storage_path" || true
  fi

  # Load DNS_POSTFIX from cluster-info.json if not already set
  if [ -z "${DNS_POSTFIX:-}" ] || [ "$DNS_POSTFIX" = "null" ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    fi
  fi

  if [ -z "${DNS_POSTFIX:-}" ] || [ "$DNS_POSTFIX" = "null" ]; then
    error "DNS_POSTFIX not configured. Run initial setup first."
    return 1
  fi

  # Get DNS server IP (VIP if HA enabled, otherwise dns-01)
  local DNS_SERVER
  DNS_SERVER=$(jq -r '.network.external.ha_vip // ""' "$CLUSTER_INFO_FILE" 2>/dev/null | cut -d'/' -f1)
  if [ -z "$DNS_SERVER" ] || [ "$DNS_SERVER" = "null" ]; then
    DNS_SERVER=$(jq -r '.external[] | select(.hostname == "dns-01") | .ip' hosts.json 2>/dev/null | cut -d'/' -f1)
  fi
  if [ -z "$DNS_SERVER" ] || [ "$DNS_SERVER" = "null" ]; then
    DNS_SERVER="10.10.0.3"  # Fallback
    warn "Could not determine DNS server, using fallback: $DNS_SERVER"
  fi

  # Render template with environment variables
  export DNS_POSTFIX DNS_SERVER
  envsubst '${DNS_POSTFIX} ${DNS_SERVER}' < "$job_file" > "/tmp/${job_name}-rendered.nomad.hcl"

  # Copy to Nomad node
  scpToAdmin "/tmp/${job_name}-rendered.nomad.hcl" "$VM_USER" "$NOMAD_IP" "/tmp/${job_name}.nomad.hcl"

  # Run the job (with optional extra args like -var)
  if ! sshRunAdmin "$VM_USER" "$NOMAD_IP" "nomad job run ${extra_run_args} /tmp/${job_name}.nomad.hcl"; then
    error "Failed to deploy $job_name"
    return 1
  fi

  # Wait for deployment and show status
  doing "Waiting for $job_name deployment..."
  sleep 5
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "nomad job status $job_name | head -25"

  success "$job_name deployed successfully!"
  return 0
}