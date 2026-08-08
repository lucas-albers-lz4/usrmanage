# SPDX-License-Identifier: Apache-2.0
#
# Wire feed first (see openwrt-feed/README.md and feeds.conf.example):
#   ./scripts/feeds update luci packages usrmanage
#   ./scripts/feeds install luci-app-usrmanage

include $(TOPDIR)/rules.mk

LUCI_TITLE:=User Management
LUCI_DESCRIPTION:=Manage local UNIX users (readonly vs admin/wheel) with operational audit log
LUCI_DEPENDS:=+luci-base +usrmanage +sudo
LUCI_PKGARCH:=all

PKG_VERSION:=0.1.4
PKG_RELEASE:=1

ifdef SOURCE_DATE_EPOCH
export SOURCE_DATE_EPOCH
endif

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Lucas Albers <lucas.b.albers@gmail.com>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
