job "backup" {
  datacenters = ["dc1"]
  type        = "batch"

  periodic {
    cron             = "${backup_cron}"
    prohibit_overlap = true
    time_zone        = "${backup_timezone}"
  }

  group "backup" {
    count = 1

    # Pin to nomad01 for consistent access to GlusterFS
    constraint {
      attribute = "$${attr.unique.hostname}"
      value     = "nomad01"
    }

    # Vault integration - fetch credentials at runtime using Workload Identity
    vault {
      role        = "backup"
      change_mode = "restart"
    }

    # Belt-and-suspenders: refuse to start if the gluster volume isn't
    # actually mounted — a backup that reads an empty /data would silently
    # archive nothing and then prune the real backups on the remote.
    task "wait-for-gluster" {
      driver = "raw_exec"
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      config {
        command = "/bin/bash"
        args = [
          "-c",
          "mountpoint -q /srv/gluster/nomad-data && test -f /srv/gluster/nomad-data/.mount-sentinel"
        ]
      }
      resources {
        cpu    = 10
        memory = 16
      }
    }

    task "backup" {
      driver = "docker"

      config {
        image        = "ubuntu:24.04"
        network_mode = "host"
        privileged   = true  # Required for NFS/SMB mount
        command      = "/bin/bash"
        args         = ["/local/backup.sh"]
        volumes = [
          "/srv/gluster/nomad-data:/data:ro",
        ]
      }

      # Backup script template - credentials injected from Vault
      template {
        data = <<SCRIPT
#!/bin/bash
set -euo pipefail

# Configuration from Vault
{{ with secret "secret/data/backup" }}
BACKUP_TYPE="{{ .Data.data.backup_type }}"
NFS_SERVER="{{ .Data.data.nfs_server }}"
NFS_PATH="{{ .Data.data.nfs_path }}"
SMB_SERVER="{{ .Data.data.smb_server }}"
SMB_SHARE="{{ .Data.data.smb_share }}"
SMB_USER="{{ .Data.data.smb_user }}"
SMB_PASSWORD="{{ .Data.data.smb_password }}"
{{ end }}

# Retention from environment (set by deployment)
RETENTION_DAYS="$${RETENTION_DAYS:-7}"

# Backup directory structure
BACKUP_DATE=$(date +%Y-%m-%d_%H%M%S)
BACKUP_DIR="/mnt/backup/proxmox-lab/$BACKUP_DATE"
MOUNT_POINT="/mnt/backup"

echo "=== Proxmox Lab Backup ==="
echo "Date: $BACKUP_DATE"
echo "Type: $BACKUP_TYPE"
echo "Retention: $RETENTION_DAYS days"

# Install required packages
apt-get update -qq
apt-get install -qq -y nfs-common cifs-utils docker.io postgresql-client > /dev/null 2>&1

# Mount backup storage
mkdir -p "$MOUNT_POINT"

if [ "$BACKUP_TYPE" = "nfs" ]; then
  echo "Mounting NFS: $NFS_SERVER:$NFS_PATH"
  mount -t nfs "$NFS_SERVER:$NFS_PATH" "$MOUNT_POINT"
elif [ "$BACKUP_TYPE" = "smb" ]; then
  echo "Mounting SMB: //$SMB_SERVER/$SMB_SHARE"
  mount -t cifs "//$SMB_SERVER/$SMB_SHARE" "$MOUNT_POINT" \
    -o username="$SMB_USER",password="$SMB_PASSWORD",vers=3.0
else
  echo "ERROR: Unknown backup type: $BACKUP_TYPE"
  exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Function to backup a directory
backup_dir() {
  local name="$1"
  local source="$2"

  if [ -d "$source" ]; then
    echo "Backing up $name..."
    tar -czf "$BACKUP_DIR/$${name}.tar.gz" -C "$(dirname "$source")" "$(basename "$source")"
    echo "  -> $BACKUP_DIR/$${name}.tar.gz"
  else
    echo "Skipping $name (directory not found: $source)"
  fi
}

# Backup Vault data
backup_dir "vault" "/data/vault"

# Backup Uptime Kuma data
backup_dir "uptime-kuma" "/data/uptime-kuma"

# Backup Authentik data directory (media, templates, certs - unified in 2025.10+)
backup_dir "authentik-data" "/data/authentik/data"

# Backup Authentik PostgreSQL database
if docker ps --format '{{.Names}}' | grep -q postgres; then
  echo "Backing up Authentik PostgreSQL database..."
  POSTGRES_CONTAINER=$(docker ps --format '{{.Names}}' | grep postgres | head -1)
  if [ -n "$POSTGRES_CONTAINER" ]; then
    docker exec "$POSTGRES_CONTAINER" pg_dump -U authentik authentik > "$BACKUP_DIR/authentik-postgres.sql"
    gzip "$BACKUP_DIR/authentik-postgres.sql"
    echo "  -> $BACKUP_DIR/authentik-postgres.sql.gz"
  fi
else
  echo "Skipping Authentik PostgreSQL (container not running)"
fi

# Backup Samba AD data
backup_dir "samba-dc01" "/data/samba-dc01"
backup_dir "samba-dc02" "/data/samba-dc02"

# Backup Traefik data
backup_dir "traefik" "/data/traefik"

# Create backup manifest
echo "Creating backup manifest..."
cat > "$BACKUP_DIR/manifest.json" <<EOF
{
  "date": "$BACKUP_DATE",
  "hostname": "$(hostname)",
  "files": $(ls -1 "$BACKUP_DIR" | grep -v manifest.json | jq -R . | jq -s .)
}
EOF

# Calculate backup size
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
echo "Backup complete: $BACKUP_SIZE"

# Cleanup old backups
echo "Cleaning up backups older than $RETENTION_DAYS days..."
find /mnt/backup/proxmox-lab -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null || true

# List remaining backups
echo "Existing backups:"
ls -1d /mnt/backup/proxmox-lab/*/ 2>/dev/null | while read dir; do
  echo "  - $(basename "$dir")"
done

# Unmount backup storage
umount "$MOUNT_POINT"

echo "=== Backup Complete ==="
SCRIPT
        destination = "local/backup.sh"
        perms       = "0755"
      }

      # Environment variables for retention
      template {
        data = <<EOH
RETENTION_DAYS={{ env "NOMAD_META_retention_days" | default "7" }}
EOH
        destination = "local/env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }

  # Metadata for configurable values
  meta {
    retention_days = "${backup_retention_days}"
  }
}
