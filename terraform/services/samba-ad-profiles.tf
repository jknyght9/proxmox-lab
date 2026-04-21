# =============================================================================
# Roaming Profiles — logon script deployed to NETLOGON share
#
# Places a logon script on DC01's sysvol that maps a network drive
# to the user's profile folder on the file server (TrueNAS/NAS).
# =============================================================================

variable "profile_server" {
  type        = string
  description = "File server for roaming profiles (e.g., truenas.jdclabs.lan or IP)"
  default     = ""
}

variable "profile_share" {
  type        = string
  description = "SMB share name for user profiles"
  default     = "profiles"
}

variable "profile_drive_letter" {
  type        = string
  description = "Drive letter to map for roaming profiles"
  default     = "P"
}

# Deploy logon script to DC01's NETLOGON share
resource "null_resource" "logon_script" {
  count      = var.deploy_samba_ad && var.profile_server != "" ? 1 : 0
  depends_on = [null_resource.ad_service_accounts]

  triggers = {
    profile_server = var.profile_server
    profile_share  = var.profile_share
    drive_letter   = var.profile_drive_letter
    ad_realm       = var.ad_realm
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
      REALM_LOWER="${lower(var.ad_realm)}"
      SCRIPTS_DIR="/opt/samba-dc01/samba/sysvol/$REALM_LOWER/scripts"

      echo "[+] Deploying logon script to NETLOGON share..."
      sudo mkdir -p "$SCRIPTS_DIR"

      # Windows logon script (batch)
      sudo tee "$SCRIPTS_DIR/logon.bat" > /dev/null <<'BATSCRIPT'
@echo off
REM Map profile drive to user's folder on file server
net use ${var.profile_drive_letter}: \\${var.profile_server}\${var.profile_share}\%USERNAME% /persistent:yes 2>nul
if errorlevel 1 (
    echo Warning: Could not map profile drive
)
BATSCRIPT

      # Linux logon script (for domain-joined Linux workstations)
      sudo tee "$SCRIPTS_DIR/logon.sh" > /dev/null <<'SHSCRIPT'
#!/bin/bash
# Mount user profile from file server
PROFILE_DIR="/home/$USER/profile"
mkdir -p "$PROFILE_DIR"
mount -t cifs //${var.profile_server}/${var.profile_share}/$USER "$PROFILE_DIR" \
  -o sec=krb5,multiuser,nofail,uid=$UID,gid=$(id -g) 2>/dev/null || \
  echo "Warning: Could not mount profile drive"
SHSCRIPT
      sudo chmod 755 "$SCRIPTS_DIR/logon.sh"
      sudo chmod 644 "$SCRIPTS_DIR/logon.bat"

      echo "[+] Logon scripts deployed to $SCRIPTS_DIR"
      echo "    - logon.bat (Windows)"
      echo "    - logon.sh (Linux)"
      echo ""
      echo "    To assign to users, set scriptPath attribute:"
      echo "    samba-tool user edit <username> --editor='sed -i s/scriptPath:/scriptPath: logon.bat/'"
      EOT
    ]
  }
}
