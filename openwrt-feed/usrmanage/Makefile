# SPDX-License-Identifier: Apache-2.0
#
# OpenWrt package: usrmanage — local UNIX user management CLI

include $(TOPDIR)/rules.mk

PKG_NAME:=usrmanage
PKG_VERSION:=0.1.14
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Lucas Albers <lucas.b.albers@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/usrmanage
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Local UNIX user management (CLI)
  # Stock OpenWrt: busybox passwd + manual passwd/group/shadow fallbacks (no shadow-*).
  DEPENDS:=+sudo +jshn +jsonfilter
  PKGARCH:=all
endef

define Package/usrmanage/description
  Manage local OpenWrt UNIX users without RADIUS: add/remove, readonly vs
  admin (wheel+sudo), compact operational audit log. Arch-independent shell
  implementation for OpenWrt 24.10 and 25.12.
endef

define Package/usrmanage/conffiles
/etc/config/usrmanage
/etc/sudoers.d/usrmanage
/etc/usrmanage/users
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/usrmanage/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/usrmanage $(1)/usr/sbin/usrmanage

	$(INSTALL_DIR) $(1)/usr/lib/usrmanage
	$(INSTALL_DATA) ./files/usr/lib/usrmanage/usrmanage-lib.sh $(1)/usr/lib/usrmanage/usrmanage-lib.sh
	$(INSTALL_DATA) ./files/usr/lib/usrmanage/usrmanage-luci-login.sh $(1)/usr/lib/usrmanage/usrmanage-luci-login.sh
	$(INSTALL_DATA) ./files/usr/lib/usrmanage/usrmanage-health.sh $(1)/usr/lib/usrmanage/usrmanage-health.sh

	$(INSTALL_DIR) $(1)/etc/sudoers.d
	$(INSTALL_DATA) ./files/etc/sudoers.d/usrmanage $(1)/etc/sudoers.d/usrmanage
	chmod 0440 $(1)/etc/sudoers.d/usrmanage

	$(INSTALL_DIR) $(1)/etc/usrmanage
	$(INSTALL_DATA) ./files/etc/usrmanage/users $(1)/etc/usrmanage/users

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-usrmanage $(1)/etc/uci-defaults/90-usrmanage
	$(INSTALL_BIN) ./files/etc/uci-defaults/91-usrmanage-diagnostic-rpc $(1)/etc/uci-defaults/91-usrmanage-diagnostic-rpc

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/usrmanage $(1)/etc/config/usrmanage
endef

$(eval $(call BuildPackage,usrmanage))
