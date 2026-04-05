include $(TOPDIR)/rules.mk

PKG_NAME:=trusttunnel-tools
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=vladdy

include $(INCLUDE_DIR)/package.mk

# TrustTunnel client binary is downloaded at install time via postinst,
# because it is a pre-built closed-source binary from AdGuard and is not
# compiled from source. The package installs only the netifd proto handler
# and hotplug scripts.

define Package/trusttunnel-tools
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=TrustTunnel VPN client (netifd integration)
  URL:=https://trusttunnel.org
  DEPENDS:=+kmod-tun +ip-full +curl
  PKGARCH:=all
endef

define Package/trusttunnel-tools/description
  Integrates TrustTunnel VPN client with OpenWRT's netifd.
  After installation, create a network interface with protocol
  "trusttunnel" via UCI or LuCI.

  The TrustTunnel binary itself (/opt/trusttunnel_client/trusttunnel_client)
  is downloaded automatically during package installation via the official
  TrustTunnel install script (supports aarch64, mipsel, mips, armv7, x86_64).
endef

define Build/Compile
	# Nothing to compile — all files are scripts
endef

define Package/trusttunnel-tools/install
	# netifd proto handler
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/trusttunnel.sh $(1)/lib/netifd/proto/trusttunnel.sh

	# WAN reconnect hotplug hook
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/99-trusttunnel $(1)/etc/hotplug.d/iface/99-trusttunnel

	# Runtime directories
	$(INSTALL_DIR) $(1)/var/run/trusttunnel
	$(INSTALL_DIR) $(1)/opt/trusttunnel_client
endef

define Package/trusttunnel-tools/postinst
#!/bin/sh
# Download TrustTunnel client binary for this architecture
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ ! -x /opt/trusttunnel_client/trusttunnel_client ]; then
		echo "Downloading TrustTunnel client binary..."
		curl -fsSL \
			https://raw.githubusercontent.com/TrustTunnel/TrustTunnelClient/refs/heads/master/scripts/install.sh \
			| sh -s - -o /opt/trusttunnel_client \
			|| echo "Warning: failed to download TrustTunnel binary. Install manually."
	fi
fi
exit 0
endef

define Package/trusttunnel-tools/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	# Bring down all TrustTunnel interfaces before removal
	for iface in $(uci show network 2>/dev/null \
		| awk -F'[.=]' '/\.proto=.trusttunnel/{print $2}'); do
		ifdown "$iface" 2>/dev/null || true
	done
fi
exit 0
endef

$(eval $(call BuildPackage,trusttunnel-tools))
