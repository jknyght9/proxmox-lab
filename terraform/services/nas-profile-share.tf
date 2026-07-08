# =============================================================================
# NAS Profile Share — auto-creates dataset, SMB share, and base NFSv4 ACL
# on each NAS that has provides_profiles=true.
#
# Idempotency:
#   - Dataset: GET /pool/dataset, create only if not found
#   - SMB share: GET /sharing/smb filtered by name, PUT if exists else POST
#   - ACL: always PUT (setacl is treated as idempotent server-side when the
#     payload matches); never use recursive=true so per-user ACLs survive
#
# The ACL on the parent dataset uses CREATOR_OWNER inheritance so that any
# per-user folder created underneath (by Windows on first logon, or by the
# profile-reconciler Nomad job) auto-inherits "owner = full control" without
# us having to special-case each user.
# =============================================================================

locals {
  # NAS hosts opted in to profile automation
  profile_nases = {
    for nas in var.nas_servers :
    nas.name => nas
    if nas.provides_profiles && nas.type == "truenas" && nas.profile_dataset != ""
  }
}

resource "null_resource" "nas_profile_share" {
  for_each = var.deploy_samba_ad ? local.profile_nases : {}
  depends_on = [
    null_resource.nas_domain_join,
  ]

  triggers = {
    address          = each.value.address
    profile_dataset  = each.value.profile_dataset
    profile_ad_group = each.value.profile_ad_group
    ad_realm         = var.ad_realm
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
      NAS_NAME="${each.key}"
      NAS_ADDR="${each.value.address}"
      API_KEY="${each.value.api_key}"
      DATASET="${each.value.profile_dataset}"
      AD_GROUP="${each.value.profile_ad_group}"
      WORKGROUP="${var.ad_domain}"
      SHARE_NAME="${var.profile_share}"
      MOUNT_PATH="/mnt/$DATASET"
      API="https://$NAS_ADDR/api/v2.0"

      echo "[+] Configuring profile share on $NAS_NAME ($NAS_ADDR)"
      echo "    dataset=$DATASET  ad_group=$AD_GROUP  mount=$MOUNT_PATH"

      auth() { curl -sk -H "Authorization: Bearer $API_KEY" "$@"; }

      # --- Step 1: Create dataset (idempotent) -----------------------------
      # TrueNAS encodes pool/dataset names with %2F in URL path. We GET the
      # specific dataset by ID; 200 = exists, 404/other = create it.
      ENCODED=$(printf '%s' "$DATASET" | sed 's|/|%2F|g')
      EXISTS=$(auth -o /dev/null -w '%%{http_code}' "$API/pool/dataset/id/$ENCODED")
      if [ "$EXISTS" = "200" ]; then
        echo "    [=] dataset $DATASET already exists"
      else
        echo "    [+] creating dataset $DATASET..."
        CREATE=$(auth -X POST -H "Content-Type: application/json" \
          "$API/pool/dataset" -d "$(jq -n --arg n "$DATASET" \
            '{name:$n, share_type:"SMB"}')")
        if echo "$CREATE" | jq -e '.error // .errno' >/dev/null 2>&1; then
          echo "[!] dataset create failed: $(echo "$CREATE" | jq -c .)"
          exit 1
        fi
      fi

      # --- Step 1b: Ensure NFSv4 ACL type (idempotent) ---------------------
      # The base ACL in Step 3 is NFSv4. If the dataset pre-existed as a
      # non-SMB (POSIX acltype) dataset, classification-datasets skipped it
      # (its EXISTS check leaves existing datasets untouched), so it can
      # still be POSIX here — and setacl then rejects the NFS4 payload with
      # EINVAL against the POSIXACE schema. Force NFSV4 + RESTRICTED aclmode
      # (the TrueNAS SMB default). No-op when already NFSV4.
      CUR_ACLTYPE=$(auth "$API/pool/dataset/id/$ENCODED" \
        | jq -r '.acltype | (.value // .parsed // .rawvalue) // "UNKNOWN"' \
        | tr '[:lower:]' '[:upper:]')
      echo "    dataset acltype=$CUR_ACLTYPE"
      if [ "$CUR_ACLTYPE" != "NFSV4" ]; then
        echo "    [+] converting acltype $CUR_ACLTYPE -> NFSV4 (aclmode=RESTRICTED)"
        UPD=$(auth -X PUT -H "Content-Type: application/json" \
          "$API/pool/dataset/id/$ENCODED" \
          -d '{"acltype":"NFSV4","aclmode":"RESTRICTED"}')
        if echo "$UPD" | jq -e '.error // .errno' >/dev/null 2>&1; then
          echo "[!] acltype update failed: $(echo "$UPD" | jq -c .)"
          exit 1
        fi
      fi

      # --- Step 2: Create or update SMB share ------------------------------
      SHARES=$(auth "$API/sharing/smb")
      SHARE_ID=$(echo "$SHARES" | jq -r --arg n "$SHARE_NAME" \
        '.[] | select(.name == $n) | .id // empty')

      SHARE_PAYLOAD=$(jq -n --arg path "$MOUNT_PATH" --arg name "$SHARE_NAME" '{
        name: $name,
        path: $path,
        purpose: "NO_PRESET",
        comment: "AD roaming profiles",
        browsable: true,
        ro: false,
        guestok: false,
        abe: true,
        home: false,
        enabled: true
      }')

      if [ -n "$SHARE_ID" ]; then
        echo "    [=] SMB share '$SHARE_NAME' exists (id=$SHARE_ID) — updating"
        RESP=$(auth -X PUT -H "Content-Type: application/json" \
          "$API/sharing/smb/id/$SHARE_ID" -d "$SHARE_PAYLOAD")
      else
        echo "    [+] creating SMB share '$SHARE_NAME'"
        RESP=$(auth -X POST -H "Content-Type: application/json" \
          "$API/sharing/smb" -d "$SHARE_PAYLOAD")
      fi
      if echo "$RESP" | jq -e '.error // .errno' >/dev/null 2>&1; then
        echo "[!] share configure failed: $(echo "$RESP" | jq -c .)"
        exit 1
      fi

      # --- Step 3: Set base NFSv4 ACL on the dataset -----------------------
      # Pattern (Windows roaming-profile classic):
      #   owner@/group@         FULL_CONTROL  inherit (defaults for root/wheel)
      #   <AD_GROUP>            EXECUTE+READ_ATTRIBUTES (parent only, no inherit)
      #                         (EXECUTE = "traverse directory" in NFSv4;
      #                         TRAVERSE is not a valid NFS4ACE advanced perm)
      #                         → users can navigate to their own folder but
      #                         not list peers (ABE handles visibility).
      #   CREATOR OWNER         FULL_CONTROL  inherit-only, dirs+files
      #                         → per-user folders created underneath
      #                         auto-inherit "owner = full control".
      #   Domain Admins         FULL_CONTROL  inherit dirs+files (admin recourse)
      # TrueNAS NFS4ACE uses `who` (not `name`) for named principals, and the
      # field is only permitted on USER/GROUP tags — never on the well-known
      # owner@/group@/everyone@ entries. AD principals are qualified as
      # WORKGROUP\name (lowercased) unless already qualified. Matches the
      # proven format in nas-acls.tf.
      ACL_PAYLOAD=$(jq -n \
        --arg path "$MOUNT_PATH" \
        --arg group "$AD_GROUP" \
        --arg wg "$WORKGROUP" \
        '
        def qualify($n):
          if ($wg != "" and ($n | test("[\\\\@]") | not) and ($n != "CREATOR OWNER"))
          then "\($wg)\\\($n | ascii_downcase)" else $n end;
        {
          path: $path,
          dacl: [
            {tag:"owner@",    id:null, type:"ALLOW", perms:{BASIC:"FULL_CONTROL"}, flags:{BASIC:"INHERIT"}},
            {tag:"group@",    id:null, type:"ALLOW", perms:{BASIC:"FULL_CONTROL"}, flags:{BASIC:"INHERIT"}},
            {tag:"GROUP",     id:null, who: qualify($group),          type:"ALLOW",
              perms:{EXECUTE:true, READ_DATA:true, READ_ATTRIBUTES:true, READ_ACL:true},
              flags:{BASIC:"NOINHERIT"}},
            {tag:"GROUP",     id:null, who: qualify("Domain Admins"), type:"ALLOW",
              perms:{BASIC:"FULL_CONTROL"},
              flags:{DIRECTORY_INHERIT:true, FILE_INHERIT:true}},
            {tag:"everyone@", id:null, type:"ALLOW",
              perms:{READ_DATA:true, EXECUTE:true, READ_ATTRIBUTES:true, READ_ACL:true},
              flags:{BASIC:"NOINHERIT"}}
          ],
          options: {stripacl:false, recursive:false, traverse:false},
          acltype: "NFS4"
        }')

      echo "    [+] applying base NFSv4 ACL on $MOUNT_PATH"
      ACL_JOB=$(auth -X POST -H "Content-Type: application/json" \
        "$API/filesystem/setacl" -d "$ACL_PAYLOAD")

      # setacl returns a job id on SCALE 25.x — poll for completion.
      # remote-exec runs this under /bin/sh (dash), so use a POSIX numeric
      # test (grep -qE), not the bash-only [[ =~ ]] which silently fell
      # through to the else branch and skipped the completion poll.
      if printf '%s' "$ACL_JOB" | grep -qE '^[0-9]+$'; then
        for i in $(seq 1 30); do
          STATE=$(auth "$API/core/get_jobs?id=$ACL_JOB" | jq -r '.[0].state // "UNKNOWN"')
          case "$STATE" in
            SUCCESS) echo "    [+] ACL applied"; break ;;
            FAILED)
              ERR=$(auth "$API/core/get_jobs?id=$ACL_JOB" | jq -r '.[0].error // "unknown"')
              echo "[!] setacl job failed: $ERR"; exit 1 ;;
            *) sleep 2 ;;
          esac
        done
      elif echo "$ACL_JOB" | jq -e '.error // .errno' >/dev/null 2>&1; then
        echo "[!] setacl failed: $(echo "$ACL_JOB" | jq -c .)"
        exit 1
      else
        echo "    [+] ACL submitted (response: $(echo "$ACL_JOB" | head -c 80))"
      fi

      echo "[+] $NAS_NAME profile share ready at //$NAS_ADDR/$SHARE_NAME"
      EOT
    ]
  }
}
