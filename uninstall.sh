#!/bin/sh
# TrustTunnel OpenWRT Uninstaller
# Usage: sh <(wget -O - https://raw.githubusercontent.com/iamvladdy/trusttunnel-openwrt/refs/heads/master/uninstall.sh)

set -e

echo "=== TrustTunnel Uninstaller ==="
echo ""

if [ ! -f /etc/openwrt_release ]; then
    echo "ERROR: This script is for OpenWRT only."
    exit 1
fi

# ---- Stop and remove UCI interfaces ----

for iface in $(uci show network 2>/dev/null \
        | awk -F'[.=]' '/\.proto=.trusttunnel/{print $2}'); do
    echo "Stopping interface $iface..."
    ifdown "$iface" 2>/dev/null || true
    uci del "network.${iface}" 2>/dev/null || true
done
uci commit network 2>/dev/null || true

# ---- Remove from podkop ----

for section in $(uci show podkop 2>/dev/null \
        | awk -F'[.=]' '/\.interface=.tun0/{print $2}'); do
    echo "Removing podkop section $section..."
    uci del "podkop.${section}" 2>/dev/null || true
done
uci commit podkop 2>/dev/null || true
service podkop restart 2>/dev/null || true

# ---- Remove scripts ----

rm -f /lib/netifd/proto/trusttunnel.sh
rm -f /etc/hotplug.d/iface/99-trusttunnel

# ---- Remove LuCI plugin ----

rm -f  /www/luci-static/resources/protocol/trusttunnel.js
rm -rf /www/luci-static/resources/view/trusttunnel
rm -f  /usr/share/rpcd/ucode/luci.trusttunnel
rm -f  /usr/share/luci/menu.d/luci-app-trusttunnel.json
rm -f  /usr/share/rpcd/acl.d/luci-app-trusttunnel.json

# ---- Remove client and runtime data ----

rm -rf /opt/trusttunnel_client
rm -rf /var/run/trusttunnel

# ---- Clean routing state ----

ip rule del prio 30801 lookup 880 2>/dev/null || true
ip rule del prio 30800 sport 1-1024 lookup main 2>/dev/null || true
ip rule del prio 30800 sport 5900-5920 lookup main 2>/dev/null || true
ip route flush table 880 2>/dev/null || true

# ---- Restart services ----

service rpcd restart 2>/dev/null || true
service network restart

echo ""
echo "=== TrustTunnel removed ==="
