# =============================================================================
# Kaneo instance-admin service account (kaneoadmin)
#
# Codifies the manual bootstrap we ran live: create a dedicated INSTANCE-ADMIN
# service account in Kaneo, promote it to admin, mint a user-scoped API key, and
# store everything at secret/kaneo-admin (a SEPARATE path from the TF-managed
# secret/kaneo, so a later apply can't clobber it — see vault-secrets.tf).
#
# This is an API/DB bootstrap, not Terraform resource management, so it uses the
# same null_resource + remote-exec (SSH → nomad01) pattern as
# null_resource.forgejo_runner_token and null_resource.authentik_apps. nomad01
# has the Nomad CLI pointed at the local agent, so `nomad alloc exec -job kaneo`
# reaches the Kaneo Postgres task on whatever node the job runs (no ACL — proven
# with the forgejo runner token).
#
# Idempotent: re-running on every apply is harmless — it short-circuits if the
# kaneoadmin account already exists. Failures (Kaneo unreachable, signup blocked)
# log an actionable message and exit 0 so they never fail the whole apply.
#
# The remote-exec output is suppressed by Terraform because the inline script
# references var.vault_token (sensitive), same as null_resource.authentik_apps.
# =============================================================================

resource "null_resource" "kaneo_admin" {
  count = var.deploy_kaneo ? 1 : 0
  depends_on = [
    nomad_job.kaneo,
    vault_kv_secret_v2.kaneo_admin,
  ]

  triggers = {
    always = timestamp()
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
      VAULT_ADDR="${var.vault_address}"
      VAULT_TOKEN="${var.vault_token}"
      KANEO_URL="https://tasks.${var.dns_postfix}"
      ADMIN_EMAIL="kaneoadmin@${var.dns_postfix}"

      echo '[+] kaneo_admin: reading Kaneo postgres password from Vault...'
      PW=$(curl -sk -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/secret/data/kaneo" | jq -r '.data.data.postgres_password // empty')
      if [ -z "$PW" ]; then
        echo "[!] kaneo_admin: could not read secret/kaneo.postgres_password (Vault down or secret/kaneo missing). Skipping — not failing apply."
        exit 0
      fi

      # Idempotency: has kaneoadmin already been provisioned? The "user" table
      # name is a reserved word in Postgres, hence the escaped double quotes.
      EXISTS=$(nomad alloc exec -task postgres -job kaneo \
        env PGPASSWORD="$PW" psql -U kaneo -d kaneo -tAc \
        "select 1 from \"user\" where email='$ADMIN_EMAIL'" 2>/dev/null | tr -d '[:space:]')
      if [ "$EXISTS" = "1" ]; then
        echo "[+] kaneo_admin: $ADMIN_EMAIL already provisioned — nothing to do."
        exit 0
      fi

      # 1) Sign up a local account (better-auth). The initial admin is exempt
      #    from DISABLE_PASSWORD_REGISTRATION, so this works even once local
      #    signup is locked down. Origin header is required by better-auth CSRF.
      echo "[+] kaneo_admin: creating $ADMIN_EMAIL via Kaneo signup API..."
      NEWPW=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
      SIGNUP=$(curl -sk --max-time 20 -X POST "$KANEO_URL/api/auth/sign-up/email" \
        -H "Content-Type: application/json" -H "Origin: $KANEO_URL" \
        -d "{\"name\":\"Kaneo Admin\",\"email\":\"$ADMIN_EMAIL\",\"password\":\"$NEWPW\"}")
      USER_ID=$(echo "$SIGNUP" | jq -r '.user.id // empty')
      if [ -z "$USER_ID" ]; then
        echo "[!] kaneo_admin: signup failed or blocked. Kaneo may be unreachable, or password registration is disabled before the first admin exists."
        echo "[!] kaneo_admin: API response: $SIGNUP"
        echo "[!] kaneo_admin: Skipping — not failing apply. See docs/services/kaneo.md to provision manually."
        exit 0
      fi

      # 2) Promote to instance admin + mark email verified directly in the DB
      #    (Kaneo has no admin-promote API; the first admin is set in the DB).
      echo "[+] kaneo_admin: promoting $ADMIN_EMAIL to instance admin (DB update)..."
      if ! nomad alloc exec -task postgres -job kaneo \
          env PGPASSWORD="$PW" psql -U kaneo -d kaneo -c \
          "update \"user\" set role='admin', email_verified=true where email='$ADMIN_EMAIL'" > /dev/null 2>&1; then
        echo "[!] kaneo_admin: DB promote failed — account exists but is not admin. Fix manually; skipping — not failing apply."
        exit 0
      fi

      # 3) Sign in to obtain a session token (used only to mint the API key).
      echo "[+] kaneo_admin: signing in to mint an API key..."
      SIGNIN=$(curl -sk --max-time 20 -X POST "$KANEO_URL/api/auth/sign-in/email" \
        -H "Content-Type: application/json" -H "Origin: $KANEO_URL" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$NEWPW\"}")
      SESSION_TOKEN=$(echo "$SIGNIN" | jq -r '.token // empty')
      if [ -z "$SESSION_TOKEN" ]; then
        echo "[!] kaneo_admin: sign-in after promote failed (response: $SIGNIN). Account is admin but no API key was minted — skipping; not failing apply."
        exit 0
      fi

      # 4) Mint a user-scoped API key (header for USE is x-api-key).
      KEYRESP=$(curl -sk --max-time 20 -X POST "$KANEO_URL/api/auth/api-key/create" \
        -H "Content-Type: application/json" -H "Origin: $KANEO_URL" \
        -H "Authorization: Bearer $SESSION_TOKEN" \
        -d "{\"name\":\"kaneoadmin-automation\"}")
      API_KEY=$(echo "$KEYRESP" | jq -r '.key // empty')
      if [ -z "$API_KEY" ]; then
        echo "[!] kaneo_admin: API key mint failed (response: $KEYRESP). Storing creds without api_key — mint one manually later."
      fi

      # 5) Store creds at secret/kaneo-admin, PRESERVING any existing
      #    forgejo_gitea_token (set out-of-band for the Forgejo/Gitea link).
      echo "[+] kaneo_admin: writing credentials to secret/kaneo-admin (preserving forgejo_gitea_token)..."
      EXISTING_GITEA=$(curl -sk -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/secret/data/kaneo-admin" | jq -r '.data.data.forgejo_gitea_token // ""')
      PAYLOAD=$(jq -nc \
        --arg email "$ADMIN_EMAIL" \
        --arg password "$NEWPW" \
        --arg uid "$USER_ID" \
        --arg key "$API_KEY" \
        --arg gitea "$EXISTING_GITEA" \
        '{data:{admin_email:$email, admin_password:$password, admin_user_id:$uid, api_key:$key, forgejo_gitea_token:$gitea}}')
      curl -sk -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H "Content-Type: application/json" \
        "$VAULT_ADDR/v1/secret/data/kaneo-admin" -d "$PAYLOAD" > /dev/null
      echo "[+] kaneo_admin: provisioned $ADMIN_EMAIL and stored creds at secret/kaneo-admin."
      EOT
    ]
  }
}
