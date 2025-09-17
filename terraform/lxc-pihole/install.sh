#!/bin/bash

set -e
export DEBIAN_FRONTEND=noninteractive
export TERM=dumb

# Define the sid repository
SID_REPO="deb http://deb.debian.org/debian sid main contrib non-free non-free-firmware"
SID_LIST="/etc/apt/sources.list.d/sid.list"
SID_PIN="/etc/apt/preferences.d/sid"
WEBSERVER_PASSWORD="changeme123"
DNS_SUFFIX="lab"

### This is a work around for DNScrypt-proxy on Debian 12
# Add the sid repo if not already added
if ! grep -q "^$SID_REPO" "$SID_LIST" 2>/dev/null; then
    echo "Adding Debian sid repository..."
    echo "$SID_REPO" | tee "$SID_LIST" > /dev/null
else
    echo "Sid repository already exists."
fi

# Add APT pinning for sid
if [ ! -f "$SID_PIN" ]; then
    echo "Creating APT pinning for sid..."
    tee "$SID_PIN" > /dev/null <<EOF
Package: *
Pin: release a=sid
Pin-Priority: 100
EOF
else
    echo "APT pinning for sid already exists."
fi
#########################################################

# Update APT package lists
echo "[+] Updating APT and installing requirements..."
apt-get update
#apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

#apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
apt-get install -y curl git unbound net-tools
apt-get install -y -t sid dnscrypt-proxy
apt-get autoremove

### Removing SID configuration and reverting to bookworm
rm -f /etc/apt/sources.list.d/sid.list /etc/apt/preferences.d/limit-sid
cat >/etc/apt/preferences.d/99-pin-bookworm <<'EOF'
Package: *
Pin: release n=bookworm
Pin-Priority: 990
EOF
apt-get update
apt-get install -y -t bookworm base-files
echo "12" > /etc/debian_version
sed -i -E 's/^(VERSION_ID=).*/\112/;
           s/^(VERSION_CODENAME=).*/\1bookworm/;
           s/^(PRETTY_NAME=).*/\1"Debian GNU\/Linux 12 (bookworm)"/' /etc/os-release
apt-mark hold dnscrypt-proxy
#########################################################

# DNScrypt-proxy config
echo "[+] Updating and restarting dnscrypt-proxy..."
cat << EOF > /etc/dnscrypt-proxy/dnscrypt-proxy.toml
listen_addresses = ['127.0.0.1:5053']
max_clients = 250
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
require_dnssec = true
require_nolog = true
require_nofilter = true
server_names = ['cloudflare', 'quad9-doh']
log_level = 2

[sources]
  [sources.public-resolvers]
  urls = ['https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = 'public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOF

# Patching systemctl to prevent dnscrypt-proxy.socket from listening on 53
echo "[+] Replacing systemd unit for dnscrypt-proxy..."
cp /usr/lib/systemd/system/dnscrypt-proxy.service /etc/systemd/system/dnscrypt-proxy.service
sed -i \
  -e '/^Requires=dnscrypt-proxy.socket/d' \
  -e '/^Also=dnscrypt-proxy.socket/d' \
  -e '/^Before=nss-lookup.target/d' \
  -e '/^Wants=nss-lookup.target/d' \
  /etc/systemd/system/dnscrypt-proxy.service

# Mask and disable the socket and resolvconf units (if not already)
systemctl disable --now dnscrypt-proxy.socket || true
systemctl mask dnscrypt-proxy.socket || true
systemctl disable --now dnscrypt-proxy-resolvconf.service || true
systemctl mask dnscrypt-proxy-resolvconf.service || true

# Reload systemd and restart the service
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now dnscrypt-proxy
systemctl restart dnscrypt-proxy

# Unbound config
echo "[+] Replacing Unbound config with strict override..."

# Wipe and replace the main config to prevent loading other files
cat << EOF > /etc/unbound/unbound.conf
include: "/etc/unbound/unbound.conf.d/pi-hole.conf"
EOF

# Create the actual configuration file used
cat << EOF > /etc/unbound/unbound.conf.d/pi-hole.conf
server:
  verbosity: 5
  interface: 127.0.0.1
  port: 5335
  do-ip4: yes
  do-udp: yes
  do-tcp: yes
  hide-identity: yes
  hide-version: yes
  qname-minimisation: yes
  harden-dnssec-stripped: no
  use-caps-for-id: yes
  cache-min-ttl: 3600
  prefetch: yes
  chroot: ""
  access-control: 127.0.0.0/8 allow
  val-permissive-mode: yes
  do-not-query-localhost: no
  #logfile: "/var/log/unbound/unbound.log"

  private-address: 192.168.0.0/16
  private-address: 169.254.0.0/16
  private-address: 172.16.0.0/12
  private-address: 10.0.0.0/8
  private-address: fd00::/8
  private-address: fe80::/10

forward-zone:
  name: "."
  forward-addr: 127.0.0.1@5053
  forward-tls-upstream: no
EOF
systemctl restart unbound

# Pihole initial configuration
echo "[+] Creating Pi-hole setupVars.conf..."
mkdir -p /etc/pihole

cat <<EOF > /etc/pihole/setupVars.conf
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=0.0.0.0/24
IPV6_ADDRESS=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
DNSMASQ_LISTENING=single
PIHOLE_DNS_1=127.0.0.1#5335
EOF

# Install Pi-hole
echo "[+] Installing Pi-hole"
curl -sSL https://install.pi-hole.net -o /root/basic-install.sh
#sed -i 's/restart_service pihole-FTL/echo \"[SKIP] restart_service pihole-FTL\"/' /root/basic-install.sh
bash /root/basic-install.sh --unattended

# Configuring Pihole
pihole-FTL --config dhcp.start 172.16.0.5
pihole-FTL --config dhcp.end 172.16.0.205
pihole-FTL --config dhcp.router 172.16.0.1
pihole-FTL --config dhcp.active true
pihole-FTL --config dns.upstreams '["127.0.0.1#5053"]'
pihole-FTL --config dns.listeningMode ALL
pihole-FTL --config dns.domain "$DNS_SUFFIX"
pihole-FTL --config webserver.api.password "$WEBSERVER_PASSWORD"
pihole-FTL --config debug.queries true
systemctl restart pihole-FTL

echo -e "[✓] PiHole Installation Complete\n"
