# Copyright (C) 2016 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-dashboard
PKG_VERSION:=1.4.10
PKG_MAINTAINER:=dashboard-community

LUCI_TITLE:=LuCI Dashboard
LUCI_DESCRIPTION:=A simple dashboard for system, network and storage status.
LUCI_DEPENDS:=+luci-app-nlbwmon
LUCI_PKGARCH:=all

LUCI_MINIFY_CSS:=0
LUCI_MINIFY_JS:=0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

# 临时修复 OpenWrt 21.02 SDK 中 luci.mk 生成的汉化包 postinst 脚本在 upgrade 时的报错
define Package/luci-i18n-dashboard-zh-cn/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	[ -f /etc/uci-defaults/luci-i18n-dashboard-zh-cn ] && {
		( . /etc/uci-defaults/luci-i18n-dashboard-zh-cn ) && rm -f /etc/uci-defaults/luci-i18n-dashboard-zh-cn
	}
	exit 0
}
endef
