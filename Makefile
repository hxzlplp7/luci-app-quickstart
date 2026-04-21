# Copyright (C) 2016 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-dashboard
PKG_VERSION:=1.4.29
PKG_MAINTAINER:=dashboard-community

LUCI_TITLE:=LuCI Dashboard
LUCI_DESCRIPTION:=A simple dashboard for system, network and storage status.
LUCI_DEPENDS:=+luci-app-nlbwmon +luci-app-samba4 +conntrack
LUCI_PKGARCH:=all

LUCI_MINIFY_CSS:=0
LUCI_MINIFY_JS:=0

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-i18n-dashboard-zh-cn/postinst
#!/bin/sh
[ -f /etc/uci-defaults/luci-i18n-dashboard-zh-cn ] && . /etc/uci-defaults/luci-i18n-dashboard-zh-cn
rm -f /etc/uci-defaults/luci-i18n-dashboard-zh-cn
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
