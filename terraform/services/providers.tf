terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    nomad = {
      source  = "hashicorp/nomad"
      version = "~> 2.4.0"
    }
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2025.2"
    }
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

provider "authentik" {
  # Use Traefik VIP or nomad01 IP directly (Docker Desktop can't resolve internal DNS)
  url      = var.traefik_ha_vip != "" ? "https://${split("/", var.traefik_ha_vip)[0]}" : "https://${var.nomad_node_ips["nomad01"]}"
  token    = var.authentik_api_token
  insecure = true # Internal CA
  headers = {
    Host = "auth.${var.dns_postfix}"
  }
}

