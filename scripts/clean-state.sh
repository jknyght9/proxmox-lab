#!/usr/bin/env bash
# clean-state.sh — wipe all generated state from the project so the next
# ./setup.sh option 1 behaves like a fresh git clone.
#
# Preserves: bootstrap.yml (user input), source code, mkdocs/docs, .git
# Removes:   crypto/, generated tfvars/pkrvars, terraform state + plugins,
#            cluster-info.json, hosts.json, .bootstrap-complete, logs,
#            rendered cloud-init dirs, root CA exports.
#
# Use --yes to skip the confirmation prompt.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

ASSUME_YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=true

TARGETS=(
  # User-generated state
  "crypto"
  "cluster-info.json"
  "hosts.json"
  ".bootstrap-complete"
  "proxmox-lab-root-ca.crt"
  "logs"

  # Terraform — Layer 1
  "terraform/terraform.tfvars"
  "terraform/.terraform"
  "terraform/.terraform.lock.hcl"

  # Terraform — Layer 2
  "terraform/services/terraform.tfvars"
  "terraform/services/.terraform"
  "terraform/services/.terraform.lock.hcl"
  "terraform/services/rendered"

  # Module-local rendered cloud-init
  "terraform/vm-nomad/rendered"
  "terraform/vm-kasm/rendered"

  # Packer
  "packer/packer.auto.pkrvars.hcl"
  "packer/packer-outputs"
)

# tfstate files use a glob pattern — collected separately
mapfile -t TFSTATES < <(find terraform terraform/services -maxdepth 2 -name 'terraform.tfstate*' 2>/dev/null || true)

echo
echo "About to remove:"
for t in "${TARGETS[@]}"; do
  if [ -e "$t" ]; then
    printf "  \033[31m✗\033[0m %s\n" "$t"
  else
    printf "  \033[2m·\033[0m %s (already gone)\n" "$t"
  fi
done
for t in "${TFSTATES[@]}"; do
  printf "  \033[31m✗\033[0m %s\n" "$t"
done

echo
echo "Preserved: bootstrap.yml, source code, .git"
echo

if [ "$ASSUME_YES" != true ]; then
  read -rp "Type 'CLEAN' to proceed: " confirm
  if [ "$confirm" != "CLEAN" ]; then
    echo "Aborted."
    exit 1
  fi
fi

for t in "${TARGETS[@]}" "${TFSTATES[@]}"; do
  [ -e "$t" ] || continue
  rm -rf -- "$t"
done

echo
echo "Done. Run ./setup.sh and choose option 1 to bootstrap fresh."
