# =============================================================================
# Netbox Inventory — populates Netbox with infrastructure records via API
#
# Uses Netbox REST API (same pattern as Authentik config — null_resource + curl).
# The e-breuninger/netbox Terraform provider validates its connection on init,
# making it unusable in a two-phase deploy. API calls avoid this issue.
#
# Gated on configure_netbox (requires Netbox to be running first).
# =============================================================================

resource "null_resource" "netbox_inventory" {
  count = var.configure_netbox ? 1 : 0

  triggers = {
    # Re-run whenever infrastructure or services change
    dns_postfix      = var.dns_postfix
    network_cidr     = var.network_cidr
    vm_inventory     = jsonencode(var.vm_inventory)
    lxc_inventory    = jsonencode(var.lxc_inventory)
    deploy_traefik   = var.deploy_traefik
    deploy_authentik = var.deploy_authentik
    deploy_samba_ad  = var.deploy_samba_ad
    deploy_netbox    = var.deploy_netbox
    deploy_uptime    = var.deploy_uptime_kuma
    deploy_lam       = var.deploy_lam
    deploy_backup    = var.deploy_backup
    deploy_tailscale = var.deploy_tailscale
    unifi_address    = var.unifi_address
  }

  # Re-run after any Nomad job is created/updated
  depends_on = [
    nomad_job.netbox,
    nomad_job.traefik,
    nomad_job.authentik,
    nomad_job.samba_ad,
    nomad_job.uptime_kuma,
    nomad_job.lam,
    nomad_job.backup,
    nomad_job.tailscale,
  ]

  connection {
    type        = "ssh"
    host        = local.nomad01_ip
    user        = "labadmin"
    private_key = file(var.ssh_admin_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      # Netbox is pinned to nomad03 by the template constraint. Reach it
      # by IP; Pi-hole DNS isn't reachable from this provisioner because
      # nomad01 (where this SSHes) still uses the gateway DNS until the
      # final deploy step. 127.0.0.1 was the prior shape — broken since
      # workload was distributed off nomad01.
      API="http://${var.nomad_node_ips["nomad03"]}:8080/api"
      TOKEN="${var.netbox_api_token}"
      AUTH="Authorization: Token $TOKEN"

      # Wait for Netbox to be healthy (detach=true means Terraform doesn't wait)
      echo '[+] Waiting for Netbox to be ready...'
      for i in $(seq 1 60); do
        if curl -sf --max-time 5 "http://${var.nomad_node_ips["nomad03"]}:8080/login/" >/dev/null 2>&1; then
          echo '[+] Netbox is ready'
          break
        fi
        [ "$i" -eq 60 ] && echo '[!] Netbox not ready after 5 minutes — skipping inventory' && exit 0
        sleep 5
      done

      # Verify API token works (v4.5+ requires API_TOKEN_PEPPERS for v2 tokens)
      API_TEST=$(curl -sk -H "$AUTH" "$API/status/" 2>/dev/null | jq -r '.detail // "ok"' 2>/dev/null)
      if [ "$API_TEST" != "ok" ]; then
        echo "[!] Netbox API token not valid yet — skipping inventory (run d5 to retry)"
        exit 0
      fi

      set -e

      echo '[+] Populating Netbox inventory...'

      # Helper: get or create a Netbox resource. Returns the ID on stdout.
      # Uses jq exact match (Netbox API search is fuzzy). Logs to stderr.
      nb_create() {
        local endpoint="$1" match_field="$2" match_value="$3" payload="$4"
        local id
        id=$(curl -sk -H "$AUTH" "$API/$endpoint/" \
          | jq -r --arg v "$match_value" --arg f "$match_field" \
            '[.results[] | select(.[$f] == $v)][0].id // empty')
        if [ -n "$id" ]; then
          echo "    $match_value exists (id=$id)" >&2
          echo "$id"
          return
        fi
        local result
        result=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X POST "$API/$endpoint/" -d "$payload")
        id=$(echo "$result" | jq -r '.id // empty')
        if [ -n "$id" ]; then
          echo "    Created $match_value (id=$id)" >&2
          echo "$id"
        else
          echo "    Failed: $(echo "$result" | jq -c .)" >&2
          echo ""
        fi
      }

      # --- Foundation ---
      echo '[+] Creating site, cluster, roles...'

      # Site name = dns_postfix verbatim (e.g. "iotvf.lab"); slug is the
      # Netbox-safe form (lowercase, dots → hyphens) since Netbox slugs
      # disallow dots and must be lowercase.
      SITE_NAME="${var.dns_postfix}"
      SITE_SLUG="${replace(lower(var.dns_postfix), ".", "-")}"
      SITE_ID=$(nb_create "dcim/sites" "slug" "$SITE_SLUG" \
        "{\"name\":\"$SITE_NAME\",\"slug\":\"$SITE_SLUG\",\"status\":\"active\"}")

      CLUSTER_TYPE_ID=$(nb_create "virtualization/cluster-types" "slug" "proxmox-ve" \
        '{"name":"Proxmox VE","slug":"proxmox-ve"}')

      CLUSTER_ID=$(nb_create "virtualization/clusters" "name" "${var.dns_postfix}" \
        "{\"name\":\"${var.dns_postfix}\",\"type\":$CLUSTER_TYPE_ID,\"site\":$SITE_ID}")

      ROLE_SERVER=$(nb_create "dcim/device-roles" "slug" "server" \
        '{"name":"Server","slug":"server","color":"4caf50"}')

      nb_create "dcim/device-roles" "slug" "network" \
        '{"name":"Network","slug":"network","color":"2196f3"}' > /dev/null

      nb_create "dcim/device-roles" "slug" "storage" \
        '{"name":"Storage","slug":"storage","color":"ff9800"}' > /dev/null

      nb_create "dcim/device-roles" "slug" "dns" \
        '{"name":"DNS","slug":"dns","color":"9c27b0"}' > /dev/null

      # --- Network Prefix ---
      echo '[+] Creating network prefix...'
      nb_create "ipam/prefixes" "prefix" "${var.network_cidr}" \
        "{\"prefix\":\"${var.network_cidr}\",\"status\":\"active\",\"site\":$SITE_ID}" > /dev/null

      # --- VMs (from Terraform vm_configs) ---
      echo '[+] Creating VMs...'
      %{for name, vm in var.vm_inventory}
      echo "  ${name}: ${vm.cores} vCPU, ${vm.memory}MB RAM, ${vm.disk_size} disk (VMID ${vm.vm_id} on ${vm.target_node})"

      # Convert disk_size to MB for Netbox (e.g., "100G" -> 102400)
      DISK_NUM=$(echo "${vm.disk_size}" | sed 's/[^0-9]//g')
      DISK_UNIT=$(echo "${vm.disk_size}" | sed 's/[0-9]//g')
      case "$DISK_UNIT" in
        T|t) DISK_MB=$((DISK_NUM * 1048576)) ;;
        G|g) DISK_MB=$((DISK_NUM * 1024)) ;;
        M|m) DISK_MB=$DISK_NUM ;;
        *)   DISK_MB=$((DISK_NUM * 1024)) ;;
      esac

      VM_ID=$(nb_create "virtualization/virtual-machines" "name" "${name}" \
        "{\"name\":\"${name}\",\"cluster\":$CLUSTER_ID,\"site\":$SITE_ID,\"status\":\"active\",\"role\":$ROLE_SERVER,\"vcpus\":${vm.cores},\"memory\":${vm.memory},\"disk\":$DISK_MB,\"comments\":\"VMID: ${vm.vm_id} | Node: ${vm.target_node}\"}")

      if [ -n "$VM_ID" ]; then
        # Update specs if VM already existed
        curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X PATCH "$API/virtualization/virtual-machines/$VM_ID/" \
          -d "{\"vcpus\":${vm.cores},\"memory\":${vm.memory},\"disk\":$DISK_MB,\"comments\":\"VMID: ${vm.vm_id} | Node: ${vm.target_node}\"}" > /dev/null

        # Create virtual disk
        VDISK_EXISTS=$(curl -sk -H "$AUTH" "$API/virtualization/virtual-disks/?virtual_machine_id=$VM_ID" \
          | jq -r '.results[0].id // empty' 2>/dev/null)
        if [ -z "$VDISK_EXISTS" ]; then
          curl -sk -H "$AUTH" -H "Content-Type: application/json" \
            -X POST "$API/virtualization/virtual-disks/" \
            -d "{\"virtual_machine\":$VM_ID,\"name\":\"scsi0\",\"size\":$DISK_MB,\"description\":\"${vm.disk_size}\"}" > /dev/null 2>&1
          echo "    Disk: scsi0 (${vm.disk_size})"
        fi

        # Create interface
        IFACE_EXISTS=$(curl -sk -H "$AUTH" "$API/virtualization/interfaces/?virtual_machine_id=$VM_ID&name=eth0" \
          | jq -r '.results[0].id // empty')
        if [ -z "$IFACE_EXISTS" ]; then
          IFACE_ID=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
            -X POST "$API/virtualization/interfaces/" \
            -d "{\"virtual_machine\":$VM_ID,\"name\":\"eth0\"}" | jq -r '.id')
        else
          IFACE_ID="$IFACE_EXISTS"
        fi

        # Create IP address
        IP_EXISTS=$(curl -sk -H "$AUTH" "$API/ipam/ip-addresses/?address=${vm.ip}/24" \
          | jq -r '.results[0].id // empty')
        if [ -z "$IP_EXISTS" ]; then
          curl -sk -H "$AUTH" -H "Content-Type: application/json" \
            -X POST "$API/ipam/ip-addresses/" \
            -d "{\"address\":\"${vm.ip}/24\",\"status\":\"active\",\"dns_name\":\"${name}.${var.dns_postfix}\",\"assigned_object_type\":\"virtualization.vminterface\",\"assigned_object_id\":$IFACE_ID}" > /dev/null
          echo "    IP ${vm.ip}/24 assigned"
        fi
      fi
      %{endfor}

      # --- LXC Containers ---
      echo '[+] Creating LXC containers...'
      ROLE_DNS=$(nb_create "dcim/device-roles" "slug" "dns" \
        '{"name":"DNS","slug":"dns","color":"9c27b0"}')

      %{for name, lxc in var.lxc_inventory}
      # Strip CIDR from IP for display
      LXC_IP_BARE=$(echo "${lxc.ip}" | cut -d/ -f1)

      echo "  ${name}: $LXC_IP_BARE (${lxc.role} on ${lxc.target_node})"

      LXC_ROLE=$ROLE_DNS
      %{if lxc.role != "dns"}
      LXC_ROLE=$ROLE_SERVER
      %{endif}

      LXC_ID=$(nb_create "virtualization/virtual-machines" "name" "${name}" \
        "{\"name\":\"${name}\",\"cluster\":$CLUSTER_ID,\"site\":$SITE_ID,\"status\":\"active\",\"role\":$LXC_ROLE,\"comments\":\"LXC container | Node: ${lxc.target_node}\"}")

      if [ -n "$LXC_ID" ]; then
        curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X PATCH "$API/virtualization/virtual-machines/$LXC_ID/" \
          -d "{\"comments\":\"LXC container | Node: ${lxc.target_node}\"}" > /dev/null

        # Create interface
        IFACE_EXISTS=$(curl -sk -H "$AUTH" "$API/virtualization/interfaces/?virtual_machine_id=$LXC_ID&name=eth0" \
          | jq -r '.results[0].id // empty')
        if [ -z "$IFACE_EXISTS" ]; then
          IFACE_ID=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
            -X POST "$API/virtualization/interfaces/" \
            -d "{\"virtual_machine\":$LXC_ID,\"name\":\"eth0\"}" | jq -r '.id')
        else
          IFACE_ID="$IFACE_EXISTS"
        fi

        # Create IP address
        IP_EXISTS=$(curl -sk -H "$AUTH" "$API/ipam/ip-addresses/?address=${lxc.ip}" \
          | jq -r '.results[0].id // empty')
        if [ -z "$IP_EXISTS" ]; then
          curl -sk -H "$AUTH" -H "Content-Type: application/json" \
            -X POST "$API/ipam/ip-addresses/" \
            -d "{\"address\":\"${lxc.ip}\",\"status\":\"active\",\"dns_name\":\"${name}.${var.dns_postfix}\",\"assigned_object_type\":\"virtualization.vminterface\",\"assigned_object_id\":$IFACE_ID}" > /dev/null
          echo "    IP ${lxc.ip} assigned"
        fi
      fi
      %{endfor}

      # --- Services ---
      echo '[+] Creating service records...'

      # Get nomad01 VM ID for service assignment
      NOMAD01_VM=$(curl -sk -H "$AUTH" "$API/virtualization/virtual-machines/?name=nomad01" \
        | jq -r '.results[0].id // empty')

      if [ -n "$NOMAD01_VM" ]; then
        nb_create "ipam/services" "name" "vault" \
          "{\"name\":\"vault\",\"virtual_machine\":$NOMAD01_VM,\"protocol\":\"tcp\",\"ports\":[8200]}" > /dev/null

        %{if var.deploy_traefik}
        nb_create "ipam/services" "name" "traefik" \
          "{\"name\":\"traefik\",\"virtual_machine\":$NOMAD01_VM,\"protocol\":\"tcp\",\"ports\":[443,80]}" > /dev/null
        %{endif}

        %{if var.deploy_authentik}
        nb_create "ipam/services" "name" "authentik" \
          "{\"name\":\"authentik\",\"virtual_machine\":$NOMAD01_VM,\"protocol\":\"tcp\",\"ports\":[9000,9443]}" > /dev/null
        %{endif}

        %{if var.deploy_netbox}
        nb_create "ipam/services" "name" "netbox" \
          "{\"name\":\"netbox\",\"virtual_machine\":$NOMAD01_VM,\"protocol\":\"tcp\",\"ports\":[8080]}" > /dev/null
        %{endif}

        %{if var.deploy_samba_ad}
        nb_create "ipam/services" "name" "samba-ad" \
          "{\"name\":\"samba-ad\",\"virtual_machine\":$NOMAD01_VM,\"protocol\":\"tcp\",\"ports\":[389,636,88,445]}" > /dev/null
        %{endif}

        %{if var.deploy_uptime_kuma}
        nb_create "ipam/services" "name" "uptime-kuma" \
          "{\"name\":\"uptime-kuma\",\"virtual_machine\":$NOMAD01_VM,\"protocol\":\"tcp\",\"ports\":[3001]}" > /dev/null
        %{endif}
      fi

      echo '[+] Netbox inventory populated'
      EOT
    ]
  }
}

# --- Proxmox Physical Servers ---
# SSHes into each Proxmox node, queries hardware via dmidecode + Proxmox API,
# and creates device records in Netbox with make/model, CPU, RAM, storage, interfaces.

resource "null_resource" "netbox_proxmox_devices" {
  for_each   = var.configure_netbox ? var.proxmox_node_ips : {}
  depends_on = [null_resource.netbox_inventory]

  triggers = {
    node_ip   = each.value
    node_name = each.key
  }

  connection {
    type        = "ssh"
    host        = each.value
    user        = "root"
    private_key = file(var.ssh_enterprise_private_key_file)
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      # No set -e — handle errors gracefully with placeholders
      NODE_NAME="${each.key}"
      NODE_IP="${each.value}"
      # Netbox is pinned to nomad03 — see netbox.nomad.hcl.tpl constraint.
      API="http://${var.nomad_node_ips["nomad03"]}:8080/api"
      TOKEN="${var.netbox_api_token}"
      AUTH="Authorization: Token $TOKEN"

      # Helper: get or create a Netbox resource. Returns the ID.
      # Uses jq to filter by exact slug/name match (API search is fuzzy).
      nb_create() {
        local endpoint="$1" match_field="$2" match_value="$3" payload="$4"
        local id
        id=$(curl -sk -H "$AUTH" "$API/$endpoint/" \
          | jq -r --arg v "$match_value" --arg f "$match_field" \
            '[.results[] | select(.[$f] == $v)][0].id // empty')
        if [ -n "$id" ]; then
          echo "$id"
          return
        fi
        id=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X POST "$API/$endpoint/" -d "$payload" | jq -r '.id // empty')
        echo "$id"
      }

      echo "[+] Gathering hardware info from $NODE_NAME ($NODE_IP)..."

      # --- Gather hardware details (fallback to baseboard, then placeholder) ---
      MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
      [ -z "$MANUFACTURER" ] && MANUFACTURER=$(dmidecode -s baseboard-manufacturer 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
      [ -z "$MANUFACTURER" ] && MANUFACTURER="Unknown Manufacturer"

      PRODUCT=$(dmidecode -s system-product-name 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
      [ -z "$PRODUCT" ] && PRODUCT=$(dmidecode -s baseboard-product-name 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
      [ -z "$PRODUCT" ] && PRODUCT="Unknown Model"

      SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
      [ -z "$SERIAL" ] && SERIAL=$(dmidecode -s baseboard-serial-number 2>/dev/null | head -1 | sed 's/[[:space:]]*$//')
      [ -z "$SERIAL" ] && SERIAL=""

      CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name" | sed 's/.*: *//' || echo "Unknown CPU")
      CPU_CORES=$(nproc 2>/dev/null || echo "0")
      RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
      RAM_GB=$(( RAM_MB / 1024 ))

      DISKS=$(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -v "^loop\|^sr\|^fd" || true)
      # Enumerate all real interfaces from /sys/class/net
      # Include: physical NICs, VLANs, WiFi
      # Exclude: loopback, virtual (veth, tap, fwbr, fwpr, docker), bridges (vmbr), bonding
      IFACES=$(ls /sys/class/net/ 2>/dev/null | grep -v "^lo$\|^veth\|^tap\|^fwbr\|^fwpr\|^vmbr\|^docker\|^bonding" || true)

      echo "  Manufacturer: $MANUFACTURER"
      echo "  Model: $PRODUCT"
      echo "  Serial: $SERIAL"
      echo "  CPU: $CPU_MODEL ($CPU_CORES cores)"
      echo "  RAM: $${RAM_GB}GB"

      # --- Create/update in Netbox ---
      MFG_SLUG=$(echo "$MANUFACTURER" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
      MFG_ID=$(nb_create "dcim/manufacturers" "slug" "$MFG_SLUG" \
        "{\"name\":\"$MANUFACTURER\",\"slug\":\"$MFG_SLUG\"}")

      DT_SLUG=$(echo "$PRODUCT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
      DT_ID=$(nb_create "dcim/device-types" "slug" "$DT_SLUG" \
        "{\"manufacturer\":$MFG_ID,\"model\":\"$PRODUCT\",\"slug\":\"$DT_SLUG\"}")

      SITE_ID=$(curl -sk -H "$AUTH" "$API/dcim/sites/?slug=${replace(lower(var.dns_postfix), ".", "-")}" | jq -r '.results[0].id')
      ROLE_ID=$(curl -sk -H "$AUTH" "$API/dcim/device-roles/?slug=server" | jq -r '.results[0].id')

      # Create or update device
      DEV_ID=$(curl -sk -H "$AUTH" "$API/dcim/devices/?name=$NODE_NAME" | jq -r '.results[0].id // empty')
      if [ -z "$DEV_ID" ]; then
        DEV_ID=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X POST "$API/dcim/devices/" \
          -d "{\"name\":\"$NODE_NAME\",\"device_type\":$DT_ID,\"role\":$ROLE_ID,\"site\":$SITE_ID,\"serial\":\"$SERIAL\",\"status\":\"active\",\"comments\":\"CPU: $CPU_MODEL ($CPU_CORES cores)\\nRAM: $${RAM_GB}GB\"}" | jq -r '.id // empty')
        echo "  Created device: $NODE_NAME (id=$DEV_ID)"
      else
        curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X PATCH "$API/dcim/devices/$DEV_ID/" \
          -d "{\"device_type\":$DT_ID,\"serial\":\"$SERIAL\",\"comments\":\"CPU: $CPU_MODEL ($CPU_CORES cores)\\nRAM: $${RAM_GB}GB\"}" > /dev/null
        echo "  Updated device: $NODE_NAME (id=$DEV_ID)"
      fi

      if [ -z "$DEV_ID" ]; then
        echo "[!] Failed to create device $NODE_NAME — skipping interfaces and disks"
        exit 0
      fi

      # Management interface + IP
      MGMT_ID=$(curl -sk -H "$AUTH" "$API/dcim/interfaces/?device_id=$DEV_ID&name=mgmt" | jq -r '.results[0].id // empty')
      if [ -z "$MGMT_ID" ]; then
        MGMT_ID=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X POST "$API/dcim/interfaces/" \
          -d "{\"device\":$DEV_ID,\"name\":\"mgmt\",\"type\":\"1000base-t\",\"mgmt_only\":true}" | jq -r '.id')
      fi

      IP_EXISTS=$(curl -sk -H "$AUTH" "$API/ipam/ip-addresses/?address=$${NODE_IP}/24" | jq -r '.results[0].id // empty')
      if [ -z "$IP_EXISTS" ]; then
        curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X POST "$API/ipam/ip-addresses/" \
          -d "{\"address\":\"$${NODE_IP}/24\",\"status\":\"active\",\"dns_name\":\"$${NODE_NAME}.${var.dns_postfix}\",\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$MGMT_ID}" > /dev/null
        echo "  IP $${NODE_IP}/24 assigned"
      fi

      IP_ID=$(curl -sk -H "$AUTH" "$API/ipam/ip-addresses/?address=$${NODE_IP}/24" | jq -r '.results[0].id // empty')
      if [ -n "$IP_ID" ]; then
        curl -sk -H "$AUTH" -H "Content-Type: application/json" \
          -X PATCH "$API/dcim/devices/$DEV_ID/" \
          -d "{\"primary_ip4\":$IP_ID}" > /dev/null
      fi

      # Network interfaces — detect type from driver/speed/sysfs
      for IFACE in $IFACES; do
        IFACE_EXISTS=$(curl -sk -H "$AUTH" "$API/dcim/interfaces/?device_id=$DEV_ID&name=$IFACE" | jq -r '.results[0].id // empty')
        if [ -z "$IFACE_EXISTS" ]; then
          SPEED=$(ethtool "$IFACE" 2>/dev/null | grep "Speed:" | awk '{print $2}' | sed 's/Mb\/s//' || echo "")
          DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | grep "^driver:" | awk '{print $2}' || echo "")
          MAC=$(cat /sys/class/net/$IFACE/address 2>/dev/null || echo "")
          [ "$MAC" = "00:00:00:00:00:00" ] && MAC=""

          # Determine Netbox interface type
          if [ -d "/sys/class/net/$IFACE/wireless" ] || [ "$DRIVER" = "iwlwifi" ] || [ "$DRIVER" = "ath9k" ]; then
            TYPE="ieee802.11ac"
          elif [ "$DRIVER" = "802.1Q" ] || [ -d "/proc/net/vlan/$IFACE" ]; then
            TYPE="virtual"
          elif [ "$SPEED" = "10000" ] || echo "$DRIVER" | grep -qE "ixgbe|i40e|ice|mlx"; then
            TYPE="10gbase-t"
          elif [ "$SPEED" = "2500" ]; then
            TYPE="2.5gbase-t"
          else
            TYPE="1000base-t"
          fi

          IF_ID=$(curl -sk -H "$AUTH" -H "Content-Type: application/json" \
            -X POST "$API/dcim/interfaces/" \
            -d "{\"device\":$DEV_ID,\"name\":\"$IFACE\",\"type\":\"$TYPE\"}" | jq -r '.id // empty')

          # Netbox v4.x: MACs are separate objects at dcim/mac-addresses/
          if [ -n "$IF_ID" ] && [ -n "$MAC" ]; then
            curl -sk -H "$AUTH" -H "Content-Type: application/json" \
              -X POST "$API/dcim/mac-addresses/" \
              -d "{\"mac_address\":\"$MAC\",\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$IF_ID}" > /dev/null 2>&1
          fi
          echo "  Interface: $IFACE type=$TYPE mac=$MAC driver=$DRIVER"
        fi
      done

      # Storage as inventory items
      echo "$DISKS" | while IFS= read -r disk_line; do
        [ -z "$disk_line" ] && continue
        DISK_NAME=$(echo "$disk_line" | awk '{print $1}')
        DISK_SIZE=$(echo "$disk_line" | awk '{print $2}')
        DISK_MODEL=$(echo "$disk_line" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')
        [ -z "$DISK_MODEL" ] && DISK_MODEL="Unknown Disk"

        INV_EXISTS=$(curl -sk -H "$AUTH" "$API/dcim/inventory-items/?device_id=$DEV_ID&name=$DISK_NAME" | jq -r '.results[0].id // empty')
        if [ -z "$INV_EXISTS" ]; then
          curl -sk -H "$AUTH" -H "Content-Type: application/json" \
            -X POST "$API/dcim/inventory-items/" \
            -d "{\"device\":$DEV_ID,\"name\":\"$DISK_NAME\",\"label\":\"$DISK_SIZE\",\"description\":\"$DISK_MODEL\"}" > /dev/null
          echo "  Disk: $DISK_NAME ($DISK_SIZE) $DISK_MODEL"
        fi
      done

      echo "[+] $NODE_NAME hardware registered in Netbox"
      EOT
    ]
  }
}

# --- UniFi Network Devices ---
# Moved to a periodic Nomad batch job: terraform/services/templates/netbox-sync.nomad.hcl.tpl
# That job runs on schedule (default every 6 hours) so device additions/removals
# in UniFi flow into Netbox without needing a Terraform apply. See nomad_job.netbox_sync.
