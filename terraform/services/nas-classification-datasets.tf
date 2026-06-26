# =============================================================================
# NAS Classification Datasets — declarative ZFS datasets on TrueNAS NASes
#
# Creates each dataset in parent-first order via the TrueNAS REST API.
# Datasets with encryption_key set become encryption roots; the hex key
# is fetched from secret/truenas/zfs-keys/<name> and supplied at create
# time. Children of an encrypted ancestor auto-inherit encryption.
#
# Idempotent: GET /pool/dataset/id/<encoded> first; POST only if 404.
#
# Lab-specific dataset layout lives in a lab-extensions overlay
# (lab-nas-classification-datasets.auto.tfvars).
# =============================================================================

variable "nas_datasets" {
  description = "ZFS datasets to provision on TrueNAS NASes (capability is consumed by a lab-extensions overlay)."
  type = list(object({
    nas            = string                      # NAS name from var.nas_servers
    name           = string                      # full dataset path, e.g. pool_data/confidential
    comment        = optional(string, "")        # human-readable description
    encryption_key = optional(string)            # name in var.zfs_encryption_keys (this dataset becomes an encryption root)
    share_type     = optional(string, "SMB") # SMB | GENERIC | NFS — SMB sets acltype=NFSV4, aclmode=RESTRICTED
  }))
  default = []
}

locals {
  # NAS lookup by name (var.nas_servers is a list)
  nas_by_name = { for nas in var.nas_servers : nas.name => nas }

  # Datasets grouped by target NAS — one null_resource per NAS
  datasets_by_nas = {
    for ds in var.nas_datasets : ds.nas => ds...
  }

  # Unique encryption key names referenced by any dataset
  nas_dataset_keys = toset([
    for ds in var.nas_datasets : ds.encryption_key if ds.encryption_key != null
  ])
}

# Read each referenced ZFS key from Vault (created by vault-zfs-keys.tf)
data "vault_kv_secret_v2" "nas_zfs_keys" {
  for_each   = local.nas_dataset_keys
  mount      = vault_mount.secret.path
  name       = "truenas/zfs-keys/${each.value}"
  depends_on = [vault_kv_secret_v2.zfs_encryption_keys]
}

resource "null_resource" "nas_classification_datasets" {
  for_each = local.datasets_by_nas

  triggers = {
    datasets_hash = sha256(jsonencode(each.value))
    nas_address   = local.nas_by_name[each.key].address
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
      NAS_NAME='${each.key}'
      NAS_ADDR='${local.nas_by_name[each.key].address}'
      API_KEY='${local.nas_by_name[each.key].api_key}'
      API="https://$NAS_ADDR/api/v2.0"

      auth() { curl -sk -H "Authorization: Bearer $API_KEY" "$@"; }

      DATASETS_JSON='${jsonencode(each.value)}'
      KEYS_JSON='${jsonencode({
      for k in local.nas_dataset_keys :
      k => jsondecode(data.vault_kv_secret_v2.nas_zfs_keys[k].data_json).key_hex
})}'

      echo "[+] Provisioning datasets on $NAS_NAME ($NAS_ADDR)"

      # Sort parent-first by path depth
      echo "$DATASETS_JSON" | jq -c 'sort_by(.name | split("/") | length) | .[]' | while read -r ds; do
        NAME=$(echo "$ds" | jq -r '.name')
        COMMENT=$(echo "$ds" | jq -r '.comment // ""')
        ENC_KEY=$(echo "$ds" | jq -r '.encryption_key // empty')
        SHARE_TYPE=$(echo "$ds" | jq -r '.share_type // "GENERIC"')
        ENCODED=$(printf '%s' "$NAME" | sed 's|/|%2F|g')

        EXISTS=$(auth -o /dev/null -w '%%{http_code}' "$API/pool/dataset/id/$ENCODED")
        if [ "$EXISTS" = "200" ]; then
          echo "    [=] $NAME exists"
          continue
        fi

        if [ -n "$ENC_KEY" ]; then
          HEX=$(echo "$KEYS_JSON" | jq -r --arg k "$ENC_KEY" '.[$k]')
          PAYLOAD=$(jq -n \
            --arg name "$NAME" \
            --arg comment "$COMMENT" \
            --arg share "$SHARE_TYPE" \
            --arg key "$HEX" '{
              name: $name,
              comments: $comment,
              share_type: $share,
              encryption: true,
              inherit_encryption: false,
              encryption_options: {
                generate_key: false,
                key: $key,
                algorithm: "AES-256-GCM"
              }
            }')
          echo "    [+] $NAME (encryption root: $ENC_KEY)"
        else
          PAYLOAD=$(jq -n \
            --arg name "$NAME" \
            --arg comment "$COMMENT" \
            --arg share "$SHARE_TYPE" '{
              name: $name,
              comments: $comment,
              share_type: $share
            }')
          echo "    [+] $NAME"
        fi

        RESP=$(auth -X POST -H "Content-Type: application/json" \
          "$API/pool/dataset" -d "$PAYLOAD")
        if echo "$RESP" | jq -e '.error // .errno' >/dev/null 2>&1; then
          echo "[!] dataset create failed for $NAME: $(echo "$RESP" | jq -c .)"
          exit 1
        fi
      done

      echo "[+] $NAS_NAME classification datasets ready"
      EOT
]
}
}
