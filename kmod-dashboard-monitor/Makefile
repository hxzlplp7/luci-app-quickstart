include $(TOPDIR)/rules.mk

PKG_NAME:=kmod-dashboard-monitor
PKG_RELEASE:=2

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/dashboard-monitor
  SUBMENU:=Network Support
  TITLE:=Dashboard realtime network monitor
  FILES:=$(PKG_BUILD_DIR)/dashboard_monitor.ko
  AUTOLOAD:=$(call AutoProbe,dashboard_monitor)
endef

define KernelPackage/dashboard-monitor/description
 A lightweight kernel monitor for luci-app-dashboard.
 It exposes realtime counters via /proc/dashboard_monitor/stats.
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	+$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" modules
endef

$(eval $(call KernelPackage,dashboard-monitor))
