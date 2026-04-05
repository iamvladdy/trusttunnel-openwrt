include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for TrustTunnel VPN
LUCI_DESCRIPTION:=Provides protocol support and status page for TrustTunnel VPN in LuCI
PKG_VERSION:=1.0.0
LUCI_DEPENDS:=+trusttunnel-tools +ucode +resolveip
LUCI_PKGARCH:=all
PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=vladdy

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-trusttunnel/install
	$(call Package/luci/install/template,$(1),luci-app-trusttunnel)

	# LuCI protocol registration
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./htdocs/luci-static/resources/protocol/trusttunnel.js \
		$(1)/www/luci-static/resources/protocol/trusttunnel.js

	# Status view
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/trusttunnel
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/trusttunnel/status.js \
		$(1)/www/luci-static/resources/view/trusttunnel/status.js

	# rpcd ucode backend
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./root/usr/share/rpcd/ucode/luci.trusttunnel \
		$(1)/usr/share/rpcd/ucode/luci.trusttunnel

	# LuCI menu entry
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-trusttunnel.json \
		$(1)/usr/share/luci/menu.d/luci-app-trusttunnel.json

	# rpcd ACL
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-trusttunnel.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-trusttunnel.json
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-trusttunnel))
