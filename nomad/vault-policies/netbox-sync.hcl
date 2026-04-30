# Vault policy for the periodic Netbox inventory sync job.
# Reads the Netbox API token, the UniFi controller credentials, and
# cluster config (for site/postfix info).

path "secret/data/netbox" {
  capabilities = ["read"]
}

path "secret/data/unifi" {
  capabilities = ["read"]
}

path "secret/data/config/cluster" {
  capabilities = ["read"]
}
