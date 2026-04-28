# =============================================================================
# Samba AD Service Accounts — managed via samba-tool CLI
#
# NOTE: The hashicorp/ad provider uses WinRM which Samba doesn't support.
# We use null_resource + docker exec samba-tool instead.
# =============================================================================

# --- Service Account Passwords ---

resource "random_password" "domain_join" {
  count            = var.deploy_samba_ad ? 1 : 0
  length           = 24
  special          = true
  override_special = "!@#%^&*"
  keepers          = { service = "domain-join" }
}

resource "random_password" "authentik_sync" {
  count            = var.deploy_samba_ad ? 1 : 0
  length           = 24
  special          = true
  override_special = "!@#%^&*"
  keepers          = { service = "authentik-sync" }
}

resource "random_password" "lam_bind" {
  count            = var.deploy_samba_ad ? 1 : 0
  length           = 24
  special          = true
  override_special = "!@#%^&*"
  keepers          = { service = "lam-bind" }
}

# --- Store service account credentials in Vault ---

resource "vault_kv_secret_v2" "samba_ad_accounts" {
  count = var.deploy_samba_ad ? 1 : 0
  mount = vault_mount.secret.path
  name  = "samba-ad/service-accounts"
  data_json = jsonencode({
    domain_join_password    = random_password.domain_join[0].result
    domain_join_dn          = "CN=domain-join-svc,CN=Users,${local.ad_base_dn}"
    authentik_sync_password = random_password.authentik_sync[0].result
    authentik_sync_dn       = "CN=authentik-sync,CN=Users,${local.ad_base_dn}"
    lam_bind_password       = random_password.lam_bind[0].result
    lam_bind_dn             = "CN=lam-admin,CN=Users,${local.ad_base_dn}"
  })
}

# --- Create OUs and Service Accounts via samba-tool ---

resource "null_resource" "ad_service_accounts" {
  count      = var.deploy_samba_ad ? 1 : 0
  depends_on = [nomad_job.samba_ad, vault_kv_secret_v2.samba_ad_accounts]

  triggers = {
    ad_realm           = var.ad_realm
    domain_join_pw     = random_password.domain_join[0].result
    authentik_sync_pw  = random_password.authentik_sync[0].result
    lam_bind_pw        = random_password.lam_bind[0].result
  }

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      set -e
      echo '[+] Waiting for Samba AD to be ready...'
      # Find container by name prefix (Nomad labels may not be present with host networking)
      CONTAINER=""
      for i in $(seq 1 30); do
        CONTAINER=$(docker ps --format '{{.ID}} {{.Names}}' | grep 'samba-ad' | head -1 | awk '{print $1}')
        if [ -n "$CONTAINER" ] && docker exec "$CONTAINER" samba-tool domain level show >/dev/null 2>&1; then
          echo '[+] Samba AD is ready'
          break
        fi
        echo "    Waiting... ($i/30)"
        CONTAINER=""
        sleep 10
      done

      if [ -z "$CONTAINER" ]; then
        echo '[!] Samba AD container not found'
        exit 1
      fi

      BASE_DN="${local.ad_base_dn}"

      # Create OU=Workstations if not exists
      echo '[+] Creating OU=Workstations...'
      docker exec $CONTAINER samba-tool ou show "OU=Workstations,$BASE_DN" 2>/dev/null || \
        docker exec $CONTAINER samba-tool ou create "OU=Workstations,$BASE_DN" --description="Domain-joined workstations"

      # Create OU=Service Accounts if not exists
      echo '[+] Creating OU=Service Accounts...'
      docker exec $CONTAINER samba-tool ou show "OU=Service Accounts,$BASE_DN" 2>/dev/null || \
        docker exec $CONTAINER samba-tool ou create "OU=Service Accounts,$BASE_DN" --description="Automated service accounts"

      # Create domain-join-svc account
      echo '[+] Creating domain-join-svc account...'
      if ! docker exec $CONTAINER samba-tool user show domain-join-svc 2>/dev/null; then
        docker exec $CONTAINER samba-tool user create domain-join-svc '${random_password.domain_join[0].result}' \
          --given-name="Domain Join" --surname="Service" \
          --description="Least-privilege account for domain joins" \
          --use-username-as-cn
        docker exec $CONTAINER samba-tool user setexpiry domain-join-svc --noexpiry
      else
        echo '    Account already exists, updating password...'
        docker exec $CONTAINER samba-tool user setpassword domain-join-svc --newpassword='${random_password.domain_join[0].result}'
      fi

      # Create authentik-sync account
      echo '[+] Creating authentik-sync account...'
      if ! docker exec $CONTAINER samba-tool user show authentik-sync 2>/dev/null; then
        docker exec $CONTAINER samba-tool user create authentik-sync '${random_password.authentik_sync[0].result}' \
          --given-name="Authentik" --surname="Sync" \
          --description="Read-only LDAP bind for Authentik user sync" \
          --use-username-as-cn
        docker exec $CONTAINER samba-tool user setexpiry authentik-sync --noexpiry
      else
        echo '    Account already exists, updating password...'
        docker exec $CONTAINER samba-tool user setpassword authentik-sync --newpassword='${random_password.authentik_sync[0].result}'
      fi

      # Create lam-admin account
      echo '[+] Creating lam-admin account...'
      if ! docker exec $CONTAINER samba-tool user show lam-admin 2>/dev/null; then
        docker exec $CONTAINER samba-tool user create lam-admin '${random_password.lam_bind[0].result}' \
          --given-name="LAM" --surname="Admin" \
          --description="LDAP Account Manager bind account" \
          --use-username-as-cn
        docker exec $CONTAINER samba-tool user setexpiry lam-admin --noexpiry
      else
        echo '    Account already exists, updating password...'
        docker exec $CONTAINER samba-tool user setpassword lam-admin --newpassword='${random_password.lam_bind[0].result}'
      fi

      # Grant domain-join-svc permission to create computer objects in OU=Workstations
      echo '[+] Delegating permissions for domain-join-svc...'
      docker exec $CONTAINER samba-tool dsacl set \
        --objectdn="OU=Workstations,$BASE_DN" \
        --sddl="(A;CI;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;$(docker exec $CONTAINER samba-tool user show domain-join-svc --attributes=objectSid 2>/dev/null | grep objectSid | awk '{print $2}'))" \
        2>/dev/null || echo '    Permission delegation may need manual setup'

      # Add lam-admin to Account Operators for user management
      echo '[+] Adding lam-admin to Account Operators...'
      docker exec $CONTAINER samba-tool group addmembers "Account Operators" lam-admin 2>/dev/null || \
        echo '    lam-admin may already be a member'

      echo '[+] Service accounts configured successfully'
      echo '    - domain-join-svc: domain join operations'
      echo '    - authentik-sync: LDAP read for Authentik'
      echo '    - lam-admin: User/group management via LAM'
      EOT
    ]
  }
}
