include $(TOPDIR)/rules.mk

PKG_NAME:=dashboard-core
PKG_VERSION:=0.0.1
PKG_RELEASE:=2

include $(INCLUDE_DIR)/package.mk

define Package/dashboard-core
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Dashboard unified backend
endef

define Package/dashboard-core/description
  Local HTTP backend for luci-app-dashboard.
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/dashboard-core \
		$(PKG_BUILD_DIR)/dashboard_core.c
endef

define Package/dashboard-core/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/dashboard-core $(1)/usr/bin/dashboard-core
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/dashboard-core.init $(1)/etc/init.d/dashboard-core
endef

$(eval $(call BuildPackage,dashboard-core))
