# Vault policy for domain join operations
# This policy allows external systems (VMs, TrueNAS) to read
# the domain-join-svc credentials needed to join the AD domain.
# Used with AppRole auth - not Nomad WIF.

# Allow reading domain join credentials from Samba AD secrets
path "secret/data/samba-ad" {
  capabilities = ["read"]
}
