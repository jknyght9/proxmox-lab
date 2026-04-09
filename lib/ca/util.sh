#!/usr/bin/env bash

# DEPRECATED: step-ca has been replaced by Vault PKI secrets engine
# These functions are kept for backwards compatibility but are no longer used.
# The Certificate Authority is now provided by Vault at:
#   - Root CA: http://<vault-ip>:8200/v1/pki/ca/pem
#   - ACME: https://vault.<domain>/v1/pki_int/acme/directory

# pushCertificatesToStepCA - DEPRECATED - Push locally-generated CA certs to step-ca LXC container
#
# DEPRECATED: This function is no longer used. CA is now provided by Vault PKI.
# Kept for reference and backwards compatibility.
function pushCertificatesToStepCA() {
  warn "pushCertificatesToStepCA is DEPRECATED - CA is now provided by Vault PKI"
  warn "Use 'Deploy Vault' (option 6) to set up the Certificate Authority"
  return 1
}

# generateCertificates - DEPRECATED - Generate step-ca certificates locally
#
# DEPRECATED: This function is no longer used. CA is now provided by Vault PKI.
# Vault PKI generates its own Root and Intermediate CA during initialization.
function generateCertificates() {
  warn "generateCertificates is DEPRECATED - CA is now provided by Vault PKI"
  warn "Vault PKI automatically generates Root and Intermediate CAs during deployment"
  return 0
}

# regenerateCA - DEPRECATED - Regenerate step-ca Certificate Authority
#
# DEPRECATED: This function is no longer used. CA is now provided by Vault PKI.
# To regenerate the CA with Vault PKI:
#   1. Delete the PKI mounts: vault secrets disable pki && vault secrets disable pki_int
#   2. Re-run the initVaultPKI function
function regenerateCA() {
  warn "regenerateCA is DEPRECATED - CA is now provided by Vault PKI"
  echo
  echo "To regenerate the Vault PKI Certificate Authority:"
  echo "  1. Connect to Vault: export VAULT_ADDR=http://nomad01:8200"
  echo "  2. Export root token: export VAULT_TOKEN=\$(jq -r .root_token crypto/vault-credentials.json)"
  echo "  3. Disable existing PKI: vault secrets disable pki && vault secrets disable pki_int"
  echo "  4. Re-deploy Vault (option 6) to regenerate PKI"
  echo
  echo "Or run the initVaultPKI function directly after disabling the mounts."
  return 1
}
