# Adding a New Nomad Service

This guide explains the pattern for adding a new service to the lab. Follow this pattern to ensure your service integrates correctly with Vault secrets, GlusterFS storage, Traefik routing, and the Layer 2 Terraform deployment.

## Pattern Overview

A new service typically requires:

1. A Nomad job HCL template in `terraform/services/templates/`
2. A `nomad_job` resource in `nomad-jobs.tf`
3. Vault KV secrets in `vault-secrets.tf`
4. A Vault JWT role in `vault-auth.tf`
5. A Vault policy in `vault-policies.tf` (and `nomad/vault-policies/`)
6. Service directories on GlusterFS in `service-directories.tf`
7. A deploy toggle variable in `variables.tf`
8. An Authentik application entry (optional, for admin-protected services)

## Step-by-Step

### 1. Add the deploy toggle variable

In `terraform/services/variables.tf`, add:

```hcl
variable "deploy_myservice" {
  type        = bool
  default     = false
  description = "Deploy My Service Nomad job"
}
```

### 2. Create the Vault policy

Create `nomad/vault-policies/myservice.hcl`:

```hcl
# Allow myservice to read its own secrets
path "secret/data/myservice" {
  capabilities = ["read"]
}

path "secret/metadata/myservice" {
  capabilities = ["read", "list"]
}

# Allow reading shared cluster config if needed
path "secret/data/config/cluster" {
  capabilities = ["read"]
}
```

### 3. Add the Vault JWT role

In `terraform/services/vault-auth.tf`, add:

```hcl
resource "vault_jwt_auth_backend_role" "myservice" {
  count          = var.deploy_myservice ? 1 : 0
  backend        = vault_jwt_auth_backend.nomad.path
  role_name      = "myservice"
  role_type      = "jwt"
  bound_audiences = ["vault.io"]
  user_claim     = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type     = "service"
  token_policies = ["myservice"]
  token_period   = 3600
  token_ttl      = 3600
  bound_claims   = { nomad_job_id = "myservice" }
}
```

Also add a `vault_policy` resource in `vault-policies.tf`:

```hcl
resource "vault_policy" "myservice" {
  count  = var.deploy_myservice ? 1 : 0
  name   = "myservice"
  policy = file("${path.module}/../../nomad/vault-policies/myservice.hcl")
}
```

### 4. Add Vault KV secrets

In `terraform/services/vault-secrets.tf`, add random password generation and the KV secret:

```hcl
resource "random_password" "myservice_admin" {
  count            = var.deploy_myservice ? 1 : 0
  length           = 20
  special          = true
  override_special = "!@#%^&*"
  keepers          = { service = "myservice" }
}

resource "vault_kv_secret_v2" "myservice" {
  count = var.deploy_myservice ? 1 : 0
  mount = vault_mount.secret.path
  name  = "myservice"
  data_json = jsonencode({
    admin_password = random_password.myservice_admin[0].result
    admin_email    = "admin@${var.dns_postfix}"
  })
}
```

### 5. Create service directories

In `terraform/services/service-directories.tf`, add to the directories list:

```hcl
resource "null_resource" "myservice_directories" {
  count      = var.deploy_myservice ? 1 : 0
  depends_on = [null_resource.nomad_vault_config]

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /srv/gluster/nomad-data/myservice",
      "sudo chmod 777 /srv/gluster/nomad-data/myservice",
    ]
  }
}
```

### 6. Write the Nomad job template

Create `terraform/services/templates/myservice.nomad.hcl.tpl`:

```hcl
job "myservice" {
  datacenters = ["dc1"]
  type        = "service"

  group "myservice" {
    count = 1

    # Pin to nomad01 for consistent DNS and routing
    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    network {
      mode = "host"
      port "http" { static = 8080 }
    }

    # GlusterFS mount guard — fail fast if not mounted
    task "wait-for-gluster" {
      driver = "raw_exec"
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      config {
        command = "/bin/bash"
        args    = ["-c", "mountpoint -q /srv/gluster/nomad-data && test -f /srv/gluster/nomad-data/.mount-sentinel"]
      }
      resources { cpu = 10; memory = 16 }
    }

    task "myservice" {
      driver = "docker"

      vault {
        role = "myservice"
      }

      config {
        image        = "myimage:latest"
        network_mode = "host"
        volumes = [
          "/srv/gluster/nomad-data/myservice:/data",
        ]
      }

      # Fetch secrets from Vault via WIF
      template {
        data = <<EOH
{{ with secret "secret/data/myservice" }}
ADMIN_PASSWORD={{ .Data.data.admin_password }}
{{ end }}
EOH
        destination = "secrets/myservice.env"
        env         = true
      }

      resources {
        cpu    = 200
        memory = 512
      }

      service {
        name     = "myservice"
        port     = "http"
        provider = "nomad"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.myservice.rule=Host(`myservice.${dns_postfix}`) || Host(`myservice`)",
          "traefik.http.routers.myservice.entrypoints=websecure",
          "traefik.http.routers.myservice.tls=true",
          "traefik.http.routers.myservice.middlewares=authentik@file",
          "traefik.http.services.myservice.loadbalancer.server.port=8080",
        ]

        check {
          type     = "http"
          path     = "/health"
          port     = "http"
          interval = "10s"
          timeout  = "3s"
        }
      }
    }
  }
}
```

Key points:
- Use `$${attr.unique.hostname}` (double dollar) in HCL templates to escape Terraform interpolation
- Use `${dns_postfix}` (single dollar) for Terraform `templatefile()` variables
- Always include the `wait-for-gluster` prestart task for services that use GlusterFS
- Use `traefik.http.routers.myservice.middlewares=authentik@file` to require authentication
- Use `vault { role = "myservice" }` and Nomad templates to fetch secrets

### 7. Add the Nomad job resource

In `terraform/services/nomad-jobs.tf`, add:

```hcl
resource "nomad_job" "myservice" {
  count      = var.deploy_myservice ? 1 : 0
  depends_on = [
    null_resource.myservice_directories,
    vault_policy.myservice,
    vault_jwt_auth_backend_role.myservice,
    vault_kv_secret_v2.myservice,
    null_resource.nomad_vault_config,
  ]

  jobspec = templatefile("${path.module}/templates/myservice.nomad.hcl.tpl", {
    dns_postfix = var.dns_postfix
  })
  detach = false
}
```

### 8. Add a DNS record (optional)

In `terraform/services/dns-records.tf`, add an entry for the service hostname. DNS records are managed via SSH to Pi-hole using `pihole-FTL --config`.

### 9. Add an Authentik application (optional)

If the service should appear in the Authentik app portal and require SSO, add it to the `null_resource.authentik_apps` provisioner in `authentik-apps.tf`. Follow the pattern of existing services (proxy provider + application).

### 10. Enable via setup.sh

Add the new service to the menu in `setup.sh`:

```bash
# In showMenu():
echo "    X) My Service"

# In the case statement:
X) enableService "myservice";;
```

The `enableService` function adds `deploy_myservice = true` to `terraform/services/terraform.tfvars` and runs `tf-services apply -auto-approve`.

## Common Patterns

### Two-phase deployment (configure after startup)

For services that need API configuration after they start (like Authentik or Netbox), follow the `enableService` pattern in `setup.sh`:

1. Set `deploy_myservice = true` and `configure_myservice = false`, apply
2. Wait for service to be healthy
3. Read API token from Vault
4. Set `configure_myservice = true` and apply again

Add the `configure_myservice` variable to `variables.tf` and guard the configuration `null_resource` with `var.configure_myservice`.

### Services with database containers

For services with PostgreSQL or similar database sidecars, add both tasks to the same task group. The application task should wait for the database to be ready using a `lifecycle { hook = "prestart" }` task or a startup script that polls the database port.

### Persisted data

Always store persistent data on GlusterFS under `/srv/gluster/nomad-data/<service>/`. Never use Nomad's ephemeral local directory for data you want to survive job rescheduling.

### Secret injection methods

**Environment variables** (for simple string secrets):
```hcl
template {
  data        = <<EOH
{{ with secret "secret/data/myservice" }}
DB_PASSWORD={{ .Data.data.db_password }}
{{ end }}
EOH
  destination = "secrets/env"
  env         = true
}
```

**Config files** (for complex configurations):
```hcl
template {
  data        = <<EOH
{{ with secret "secret/data/myservice" }}
[database]
password = {{ .Data.data.db_password }}
{{ end }}
EOH
  destination = "local/myservice.conf"
}
```

## Testing Your Service

After adding the service:

```bash
# Apply Layer 2 with the new service
docker compose run terraform-services apply -auto-approve

# Check job status
ssh labadmin@nomad01 "nomad job status myservice"

# View logs
ssh labadmin@nomad01 "nomad alloc logs -job myservice"

# Test via Traefik
curl -sk https://myservice.<dns-suffix>/ | head -5

# Verify Vault WIF is working (check that secrets are populated in the container)
CONTAINER=$(ssh labadmin@nomad01 "docker ps --format '{{.ID}} {{.Names}}' | grep myservice | head -1 | awk '{print $1}'")
ssh labadmin@nomad01 "docker exec $CONTAINER env | grep ADMIN_PASSWORD"
```
