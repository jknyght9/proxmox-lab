#!/usr/bin/env bash

# Generic function for deploying Nomad jobs
# Parameters: job_name, job_file, [storage_path], [extra_run_args]
#   extra_run_args: additional args passed to `nomad job run`, e.g. "-var foo=bar"
#
# Job files are passed directly to `nomad job run` — no envsubst.
# All variable substitution uses Nomad HCL2 variables via -var flags.
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
    error "No Nomad nodes found in hosts.json. Deploy Nomad first."
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

  # Copy job file to Nomad node and run it
  scpToAdmin "$job_file" "$VM_USER" "$NOMAD_IP" "/tmp/${job_name}.nomad.hcl"

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
