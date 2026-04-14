# Luci App Dashboard 🚀

![License](https://img.shields.io/github/license/hxzlplp7/luci-app-dashboard)
![Version](https://img.shields.io/github/v/tag/hxzlplp7/luci-app-dashboard?label=version)
![Build Status](https://github.com/hxzlplp7/luci-app-dashboard/actions/workflows/release.yml/badge.svg)

这是一个专为 OpenWrt/LEDE 路由器设计的**现代化、极客风格**的仪表盘 (Dashboard) 插件。它不仅提供了直观的系统状态监控，还采用了先进的前端技术打造了丝滑的交互体验。

本项目是对原版 `luci-app-quickstart` 的深度重构与视觉进化版。

## ✨ 核心特性

- 📈 **实时折线流量监控**：采用 **Apache ECharts** 引擎，支持渐变色实时双向网速监控，精确捕捉每一秒的带宽波动。
- 🌍 **公网 IP 嗅探**：原生集成异步公网 IP 自检功能，并能识别地理位置归属，一眼看穿网络连接质量。
- ⏱️ **丝滑时钟同步**：采用前端计数 + 后端校准技术，实现运行时间、系统时钟的秒级平滑跳动，极低系统负载。
- 🌡️ **全维度硬件健康**：深度获取 CPU 使用率、实时温度、内存占用率，以及固件版本、内核版本、DNS 服务器等核心参数。
- 🛡️ **纯净且独立**：完全移除原版对 iStoreOS 生态、易有云 (LinkEase)、DDNSTO 等专有云服务的依赖，保持系统整洁。
- 🌐 **多语言支持**：完整的 I18n 国际化架构，支持英文主体包与独立的中文化包分布。

## 🛠️ 依赖关系

在使用或编译本插件前，请确保系统中已安装以下核心依赖：
- `luci-app-nlbwmon`：用于获取网络接口流量统计。

## 📦 如何安装/编译

### 1. 直接安装 (推荐)
前往 [Releases 页面](https://github.com/hxzlplp7/luci-app-dashboard/releases) 下载最新的 `.ipk` 文件。
通常需要安装两个包：
* `luci-app-dashboard_xxxx_all.ipk` (项目主体)
* `luci-i18n-dashboard-zh-cn_xxxx_all.ipk` (中文汉化，可选)

安装后请清理 LuCI 缓存：
```bash
rm -f /tmp/luci-indexcache
```

### 2. 源码编译
将源码放入 OpenWrt SDK 的 `package` 目录：
```bash
git clone https://github.com/hxzlplp7/luci-app-dashboard.git package/luci-app-dashboard
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig # 选择 LuCI -> Applications -> luci-app-dashboard
make package/luci-app-dashboard/compile V=s
```

## 📜 协议与授权

本代码遵循 **Apache License, Version 2.0** 协议。详细内容请参阅 `LICENSE` 文件。

---
*Created with ❤️ by dashboard-community.*
