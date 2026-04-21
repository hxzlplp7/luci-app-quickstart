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
LUCI_DEPENDS:=+luci-app-nlbwmon +luci-app-samba4 +conntrack +arp-scan
LUCI_PKGARCH:=all

LUCI_MINIFY_CSS:=0
LUCI_MINIFY_JS:=0

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-dashboard/postinst
#!/bin/sh
ROOT="$${IPKG_INSTROOT:-}"
DEFAULT_DIR="/usr/share/luci-app-dashboard/oaf-default"
FEATURE_ROOT="/etc/appfilter"
FEATURE_FILE="$${FEATURE_ROOT}/feature.cfg"
VERSION_FILE="$${FEATURE_ROOT}/version.txt"
ICON_DST="/www/luci-static/resources/app_icons"
DEFAULT_VERSION="v25.9.29"

if [ ! -f "$${ROOT}$${FEATURE_FILE}" ] && [ -f "$${ROOT}$${DEFAULT_DIR}/feature.cfg" ]; then
	mkdir -p "$${ROOT}$${FEATURE_ROOT}"
	cp -f "$${ROOT}$${DEFAULT_DIR}/feature.cfg" "$${ROOT}$${FEATURE_FILE}"

	if [ -d "$${ROOT}$${DEFAULT_DIR}/app_icons" ]; then
		mkdir -p "$${ROOT}$${ICON_DST}"
		cp -fpR "$${ROOT}$${DEFAULT_DIR}/app_icons/." "$${ROOT}$${ICON_DST}/" 2>/dev/null
	fi

	printf '%s\n' "$${DEFAULT_VERSION}" > "$${ROOT}$${VERSION_FILE}"
fi

exit 0
endef

define Package/luci-i18n-dashboard-zh-cn/postinst
#!/bin/sh
[ -f /etc/uci-defaults/luci-i18n-dashboard-zh-cn ] && . /etc/uci-defaults/luci-i18n-dashboard-zh-cn
rm -f /etc/uci-defaults/luci-i18n-dashboard-zh-cn
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
