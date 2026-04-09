#!/usr/bin/env bash

# deployBackupOnly - Configure and deploy automated backups as a periodic Nomad job
#
# Prerequisites:
#   - Nomad cluster running and healthy
#   - Vault deployed and unsealed
#   - NFS or SMB backup target accessible from Nomad nodes
#
# Globals read: DNS_POSTFIX, KEY_PATH, VM_USER, VAULT_CREDENTIALS_FILE, SCRIPT_DIR, CLUSTER_INFO_FILE
# Arguments: None
# Returns: 0 on success, 1 on failure
#
# Side effects:
#   - Stores backup credentials in Vault KV store
#   - Creates Vault policy and WIF role for backup job
#   - Saves backup config to cluster-info.json
#   - Deploys periodic Nomad job
function deployBackupOnly() {
  cat <<EOF

############################################################################
Automated Backup Configuration

Configure automated backups to NFS or SMB network storage.
Requires: Nomad cluster running, Vault for credentials
#############################################################################

EOF

  ensureClusterContext || return 1
  ensureNomadCluster || return 1

  # Check Vault is deployed (required for credentials)
  if ! isVaultDeployed 2>/dev/null; then
    error "Vault is not deployed. Deploy Vault first (option 8)."
    return 1
  fi
  success "Vault is running"

  # Check credentials file exists
  if [ ! -f "$VAULT_CREDENTIALS_FILE" ]; then
    error "Vault credentials file not found: $VAULT_CREDENTIALS_FILE"
    info "Deploy Vault first (option 8) to generate credentials."
    return 1
  fi

  # Get Vault connection info
  local VAULT_ADDR ROOT_TOKEN
  VAULT_ADDR=$(jq -r '.vault_address // empty' "$VAULT_CREDENTIALS_FILE")
  ROOT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_CREDENTIALS_FILE")

  if [ -z "$VAULT_ADDR" ] || [ -z "$ROOT_TOKEN" ]; then
    error "Could not read Vault credentials from $VAULT_CREDENTIALS_FILE"
    return 1
  fi

  # Check if Vault is sealed and unseal if needed
  doing "Checking Vault seal status..."
  if isVaultSealed; then
    warn "Vault is sealed, attempting to unseal..."
    if ! unsealVault; then
      error "Could not unseal Vault. Cannot configure backups."
      info "Run 'Unseal Vault' (option 10) manually if needed."
      return 1
    fi
  fi
  success "Vault is unsealed"

  # Get first Nomad node IP
  local NOMAD_IP
  NOMAD_IP=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  # Load existing backup config if present
  local EXISTING_CONFIG=""
  if [ -f "$CLUSTER_INFO_FILE" ]; then
    EXISTING_CONFIG=$(jq -r '.backup_config // empty' "$CLUSTER_INFO_FILE")
  fi

  # Check if backup job already exists
  if isBackupConfigured 2>/dev/null; then
    warn "Backup job is already configured."
    read -rp "$(question "Reconfigure backups? [y/N]: ")" RECONFIGURE
    RECONFIGURE=${RECONFIGURE:-N}
    if [[ ! "$RECONFIGURE" =~ ^[Yy]$ ]]; then
      info "Keeping existing backup configuration."
      return 0
    fi
  fi

  echo
  info "Configure backup storage"
  echo

  # Backup type selection
  local BACKUP_TYPE
  echo "Select backup storage type:"
  echo "  1) NFS (Network File System)"
  echo "  2) SMB/CIFS (Windows/Samba share)"
  echo
  read -rp "$(question "Storage type [1-2]: ")" BACKUP_TYPE_CHOICE

  case "$BACKUP_TYPE_CHOICE" in
    1) BACKUP_TYPE="nfs" ;;
    2) BACKUP_TYPE="smb" ;;
    *)
      error "Invalid selection"
      return 1
      ;;
  esac

  # Collect storage details
  local NFS_SERVER="" NFS_PATH=""
  local SMB_SERVER="" SMB_SHARE="" SMB_USER="" SMB_PASSWORD=""

  if [ "$BACKUP_TYPE" = "nfs" ]; then
    echo
    info "NFS Configuration"
    read -rp "$(question "NFS server hostname/IP: ")" NFS_SERVER
    read -rp "$(question "NFS export path (e.g., /backups): ")" NFS_PATH

    # Test NFS connectivity from Nomad node
    doing "Testing NFS connectivity from $NOMAD_IP..."
    if sshRunAdmin "$VM_USER" "$NOMAD_IP" "showmount -e $NFS_SERVER 2>/dev/null | grep -q '$NFS_PATH'" 2>/dev/null; then
      success "NFS export is accessible"
    else
      warn "Could not verify NFS export. Ensure $NFS_SERVER:$NFS_PATH is accessible from Nomad nodes."
      read -rp "$(question "Continue anyway? [y/N]: ")" CONTINUE
      CONTINUE=${CONTINUE:-N}
      if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        return 1
      fi
    fi

  else  # SMB
    echo
    info "SMB/CIFS Configuration"
    read -rp "$(question "SMB server hostname/IP: ")" SMB_SERVER
    read -rp "$(question "SMB share name (e.g., Backups): ")" SMB_SHARE
    read -rp "$(question "SMB username: ")" SMB_USER
    read -rsp "$(question "SMB password: ")" SMB_PASSWORD
    echo
  fi

  # Retention policy
  echo
  info "Retention Policy"
  read -rp "$(question "Days to keep backups [7]: ")" RETENTION_DAYS
  RETENTION_DAYS=${RETENTION_DAYS:-7}

  # Schedule configuration
  echo
  info "Backup Schedule (cron format)"
  info "Examples:"
  info "  0 2 * * *   = Daily at 2 AM"
  info "  0 2 * * 0   = Weekly on Sunday at 2 AM"
  info "  0 2 1 * *   = Monthly on the 1st at 2 AM"
  read -rp "$(question "Cron schedule [0 2 * * *]: ")" BACKUP_CRON
  BACKUP_CRON=${BACKUP_CRON:-"0 2 * * *"}

  # Timezone
  read -rp "$(question "Timezone [UTC]: ")" BACKUP_TIMEZONE
  BACKUP_TIMEZONE=${BACKUP_TIMEZONE:-UTC}

  # Store credentials in Vault
  doing "Storing backup credentials in Vault..."

  local SECRET_PAYLOAD
  SECRET_PAYLOAD=$(jq -n \
    --arg backup_type "$BACKUP_TYPE" \
    --arg nfs_server "${NFS_SERVER:-}" \
    --arg nfs_path "${NFS_PATH:-}" \
    --arg smb_server "${SMB_SERVER:-}" \
    --arg smb_share "${SMB_SHARE:-}" \
    --arg smb_user "${SMB_USER:-}" \
    --arg smb_password "${SMB_PASSWORD:-}" \
    '{data: {
      backup_type: $backup_type,
      nfs_server: $nfs_server,
      nfs_path: $nfs_path,
      smb_server: $smb_server,
      smb_share: $smb_share,
      smb_user: $smb_user,
      smb_password: $smb_password
    }}')

  if ! curl -skf --connect-timeout 5 --max-time 10 -X POST \
    "${VAULT_ADDR}/v1/secret/data/backup" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$SECRET_PAYLOAD" > /dev/null; then
    error "Failed to store credentials in Vault"
    return 1
  fi

  success "Credentials stored in Vault at secret/data/backup"

  # Create Vault policy for backup job
  doing "Creating backup policy in Vault..."

  local BACKUP_POLICY
  BACKUP_POLICY=$(cat "$SCRIPT_DIR/nomad/vault-policies/backup.hcl")

  if ! curl -skf --connect-timeout 5 --max-time 10 -X PUT \
    "${VAULT_ADDR}/v1/sys/policies/acl/backup" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"policy\": $(echo "$BACKUP_POLICY" | jq -Rs .)}" > /dev/null; then
    error "Failed to create backup policy"
    return 1
  fi

  success "Created backup policy"

  # Create Vault WIF role for backup job
  doing "Creating Vault WIF role for backup job..."

  local BACKUP_ROLE
  BACKUP_ROLE=$(cat <<'ROLE_JSON'
{
  "role_type": "jwt",
  "bound_audiences": ["vault.io"],
  "user_claim": "/nomad_job_id",
  "user_claim_json_pointer": true,
  "claim_mappings": {
    "nomad_namespace": "nomad_namespace",
    "nomad_job_id": "nomad_job_id",
    "nomad_task": "nomad_task"
  },
  "token_type": "service",
  "token_policies": ["backup"],
  "token_period": "1h",
  "token_ttl": "1h",
  "bound_claims": {
    "nomad_job_id": "backup"
  }
}
ROLE_JSON
)

  if ! curl -skf --connect-timeout 5 --max-time 10 -X POST \
    "${VAULT_ADDR}/v1/auth/jwt-nomad/role/backup" \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$BACKUP_ROLE" > /dev/null; then
    error "Failed to create backup Vault role"
    return 1
  fi

  success "Created Vault role 'backup'"

  # Save config to cluster-info.json
  doing "Saving backup configuration..."

  local SERVER_INFO
  if [ "$BACKUP_TYPE" = "nfs" ]; then
    SERVER_INFO="$NFS_SERVER:$NFS_PATH"
  else
    SERVER_INFO="//$SMB_SERVER/$SMB_SHARE"
  fi

  local tmp_file
  tmp_file=$(mktemp)
  jq --arg type "$BACKUP_TYPE" \
     --arg server "$SERVER_INFO" \
     --arg retention "$RETENTION_DAYS" \
     --arg cron "$BACKUP_CRON" \
     --arg tz "$BACKUP_TIMEZONE" \
     '. + {
       backup_config: {
         enabled: true,
         type: $type,
         server: $server,
         retention_days: ($retention | tonumber),
         schedule: $cron,
         timezone: $tz
       }
     }' "$CLUSTER_INFO_FILE" > "$tmp_file" && mv "$tmp_file" "$CLUSTER_INFO_FILE"

  success "Backup configuration saved to cluster-info.json"

  # Deploy the backup job
  doing "Deploying backup job to Nomad..."

  # Load DNS_POSTFIX (needed for job template rendering)
  if [ -z "${DNS_POSTFIX:-}" ] || [ "$DNS_POSTFIX" = "null" ]; then
    if [ -f "$CLUSTER_INFO_FILE" ]; then
      DNS_POSTFIX=$(jq -r '.dns_postfix // ""' "$CLUSTER_INFO_FILE")
    fi
  fi

  # Render job template with configuration
  export BACKUP_CRON BACKUP_TIMEZONE BACKUP_RETENTION_DAYS="$RETENTION_DAYS"
  envsubst '${BACKUP_CRON} ${BACKUP_TIMEZONE} ${BACKUP_RETENTION_DAYS}' \
    < "nomad/jobs/backup.nomad.hcl" > "/tmp/backup-rendered.nomad.hcl"

  # Copy to Nomad node
  scpToAdmin "/tmp/backup-rendered.nomad.hcl" "$VM_USER" "$NOMAD_IP" "/tmp/backup.nomad.hcl"

  # Run the job
  if ! sshRunAdmin "$VM_USER" "$NOMAD_IP" "nomad job run /tmp/backup.nomad.hcl"; then
    error "Failed to deploy backup job"
    return 1
  fi

  # Clean up
  rm -f "/tmp/backup-rendered.nomad.hcl"
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "rm -f /tmp/backup.nomad.hcl"

  # Show job status
  sleep 2
  sshRunAdmin "$VM_USER" "$NOMAD_IP" "nomad job status backup | head -25"

  success "Backup job deployed successfully!"

  echo
  info "Backup Configuration Summary:"
  info "  Type: $BACKUP_TYPE"
  info "  Target: $SERVER_INFO"
  info "  Schedule: $BACKUP_CRON ($BACKUP_TIMEZONE)"
  info "  Retention: $RETENTION_DAYS days"
  echo
  info "Management commands:"
  info "  View status:        nomad job status backup"
  info "  Trigger manually:   nomad job periodic force backup"
  info "  View logs:          nomad alloc logs -job backup"
  info "  Stop backups:       nomad job stop backup"
  echo
  info "Credentials stored in Vault at: secret/data/backup"

  success "Backup configuration complete!"
}

# Check if backup job is configured
function isBackupConfigured() {
  local nomad_ip
  nomad_ip=$(jq -r '.external[] | select(.hostname | startswith("nomad")) | .ip' hosts.json 2>/dev/null | head -1 | cut -d'/' -f1)

  [ -z "$nomad_ip" ] && return 1

  # Check if job exists (periodic jobs show as "dead" when not running but still exist)
  local status
  status=$(sshRunAdmin "$VM_USER" "$nomad_ip" "nomad job status backup 2>/dev/null | grep -c 'Status'" 2>/dev/null || echo "0")

  [ "$status" -gt 0 ]
}
