#!/bin/sh
# TrustTunnel OpenWRT Installer
# Usage: sh <(wget -O - https://raw.githubusercontent.com/iamvladdy/trusttunnel-openwrt/refs/heads/master/install.sh)

set -e

REPO="iamvladdy/trusttunnel-openwrt"
BRANCH="master"
RAW="https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}"

echo "=== TrustTunnel Installer for OpenWRT ==="
echo ""

# ---- Checks ----

if [ ! -f /etc/openwrt_release ]; then
    echo "ERROR: This script is for OpenWRT only."
    exit 1
fi

# ---- Detect package manager ----

if command -v apk >/dev/null 2>&1; then
    PKG_UPDATE="apk update"
    PKG_INSTALL="apk add"
    echo "Package manager: apk (OpenWRT 25.x)"
elif command -v opkg >/dev/null 2>&1; then
    PKG_UPDATE="opkg update"
    PKG_INSTALL="opkg install"
    echo "Package manager: opkg (OpenWRT 24.x)"
else
    echo "ERROR: Neither apk nor opkg found."
    exit 1
fi

echo ""

# ---- Install dependencies ----

echo "Installing dependencies..."
$PKG_UPDATE
$PKG_INSTALL kmod-tun ip-full curl
echo ""

# ---- Install files from repo ----

_install() {
    local url="$1"
    local dst="$2"
    local mode="${3:-0644}"
    mkdir -p "$(dirname "$dst")"
    wget -qO "$dst" "$url"
    chmod "$mode" "$dst"
    echo "  installed: $dst"
}

echo "Installing netifd proto handler..."
_install "$RAW/trusttunnel.sh" \
    /lib/netifd/proto/trusttunnel.sh 0755

echo "Installing hotplug hook..."
_install "$RAW/99-trusttunnel" \
    /etc/hotplug.d/iface/99-trusttunnel 0755

echo "Installing LuCI plugin..."
_install "$RAW/luci/protocol/trusttunnel.js" \
    /www/luci-static/resources/protocol/trusttunnel.js
_install "$RAW/luci/view/trusttunnel/status.js" \
    /www/luci-static/resources/view/trusttunnel/status.js
_install "$RAW/luci/rpcd/luci.trusttunnel" \
    /usr/share/rpcd/ucode/luci.trusttunnel
_install "$RAW/luci/menu/luci-app-trusttunnel.json" \
    /usr/share/luci/menu.d/luci-app-trusttunnel.json
_install "$RAW/luci/acl/luci-app-trusttunnel.json" \
    /usr/share/rpcd/acl.d/luci-app-trusttunnel.json

# Restart LuCI services to pick up new files
service rpcd restart 2>/dev/null || true
service uhttpd restart 2>/dev/null || true

echo ""

# ---- Install/Update TrustTunnel client binary ----

mkdir -p /opt/trusttunnel_client

echo "Downloading TrustTunnel client binary..."
curl -fsSL \
    https://raw.githubusercontent.com/TrustTunnel/TrustTunnelClient/refs/heads/master/scripts/install.sh \
    | sh -s - -o /opt/trusttunnel_client

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo ""
echo "1. Copy your server config to the router:"
echo "     scp config.toml root@<router>:/opt/trusttunnel_client/trusttunnel_client.toml"
echo ""
echo "   Make sure [listener.tun] in the config has:"
echo "     included_routes = []"
echo "     excluded_routes = []"
echo "     change_system_dns = false"
echo ""
echo "2. Create a network interface:"
echo "     uci set network.tun0=interface"
echo "     uci set network.tun0.proto=trusttunnel"
echo "     uci set network.tun0.config_file=/opt/trusttunnel_client/trusttunnel_client.toml"
echo "     uci commit network"
echo "     service network restart"
echo ""
echo "   Or use LuCI: Network > Interfaces > Add > Protocol: TrustTunnel VPN"
echo ""
echo "3. Status: LuCI > Status > TrustTunnel"
