# Vault policy for the periodic Netbox inventory sync job.
# Reads the Netbox API token, the UniFi controller credentials, and
# cluster config (for site/postfix info).

path "secret/data/infra/netbox/app" {
  capabilities = ["read"]
}

path "secret/data/infra/unifi/udm" {
  capabilities = ["read"]
}

path "secret/data/infra/config/cluster" {
  capabilities = ["read"]
}
