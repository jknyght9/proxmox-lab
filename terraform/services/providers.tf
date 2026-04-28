terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.6.0"
    }
    # NOTE: e-breuninger/netbox provider is added dynamically when
    # configure_netbox=true (see netbox-inventory.tf). The provider validates
    # its connection on init, so it can't be declared here before Netbox is running.
    #
    # NOTE: goauthentik/authentik provider has bugs with invalidation_flow
    # on OAuth2, LDAP, and intermittently on proxy providers.
    # All Authentik config managed via API (null_resource + curl) instead.
    #
    # NOTE: ryanwholey/pihole provider is incompatible with Pi-hole v6.6+
    # (uses legacy PHP API, not the new /api/ REST endpoint)
    # DNS records managed via null_resource + pihole-FTL CLI instead
  }
}

provider "vault" {
  address          = var.vault_address
  token            = var.vault_token
  skip_tls_verify  = true
  skip_child_token = true
}

provider "nomad" {
  address = var.nomad_address
}


