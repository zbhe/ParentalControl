include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-parental
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-parental
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI parental control
  DEPENDS:=+luci-base +firewall4 +nftables
endef

define Package/luci-app-parental/description
  Per-device parental controls for OpenWrt using LuCI and nftables.
  Supports multiple time ranges, per-range weekdays, and overnight ranges.
endef

define Package/luci-app-parental/conffiles
/etc/config/parental
endef

define Package/luci-app-parental/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/parental $(1)/etc/config/parental
	$(INSTALL_BIN) ./files/etc/config/firewall.parental $(1)/etc/config/firewall.parental

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-parental $(1)/etc/uci-defaults/90-parental

	$(INSTALL_DIR) $(1)/usr/lib/parental
	$(INSTALL_BIN) ./files/usr/lib/parental/firewall-include.sh $(1)/usr/lib/parental/firewall-include.sh

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/parental.lua $(1)/usr/lib/lua/luci/controller/parental.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/parental_script.lua $(1)/usr/lib/lua/luci/model/cbi/parental_script.lua
endef

define Package/luci-app-parental/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -x /usr/lib/parental/firewall-include.sh ] && /usr/lib/parental/firewall-include.sh add
exit 0
endef

define Package/luci-app-parental/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -x /usr/lib/parental/firewall-include.sh ] && /usr/lib/parental/firewall-include.sh remove
exit 0
endef

$(eval $(call BuildPackage,luci-app-parental))
