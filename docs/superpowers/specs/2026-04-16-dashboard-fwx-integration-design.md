# Dashboard 与 FWX 功能集成设计

## 概述

本文档定义了将 `fanchmwrt-packages` 中已确认范围的能力，第一阶段集成到 `luci-app-dashboard` 的设计方案。

目标不是直接把原仓库代码原样搬进来，而是在 `luci-app-dashboard` 内构建一个“单页 LuCI Dashboard 外壳 + 模块化内核”的实现，并且要求它在标准 OpenWrt 环境下可运行，不依赖 `fwxd` 或 `kmod-fwx`。

第一阶段覆盖以下功能域：

- Dashboard 总览
- Dashboard 设置
- 用户管理与用户详情
- 网络设置
- 系统设置
- 上网记录设置
- 特征库

第一阶段不包含以下内容：

- 应用过滤
- MAC 过滤
- 任何必须依赖 `fwx` 内核级应用识别语义才能正确成立的深度功能

## 目标

- 保留 `/admin/dashboard` 作为唯一入口页面。
- 保持“仪表盘优先”的交互形态，而不是恢复成原 `fwx` 的多页面菜单结构。
- 用标准 OpenWrt 可用的数据源和配置存储替代 `fwx` 后端依赖。
- 将当前 dashboard 重构为模块化前后端，而不是继续扩张现有控制器和模板。
- 在 `nlbwmon`、DNS 日志、特征包等可选能力缺失时，提供明确的降级行为。

## 非目标

- 不追求与 `fwxd` 环境下的行为完全等价。
- 不集成 `luci-app-fwx-appfilter`。
- 不集成 `luci-app-fwx-macfilter`。
- 不引入新的完整 SPA 前端构建体系。
- 不承诺在普通 OpenWrt 上复现 `fwx` 级别的应用识别精度。

## 已确认的范围决策

用户已经确认以下产品与实现方向：

- 目标是“真实集成到 `luci-app-dashboard`”，不是菜单包装。
- 第一阶段范围是 `dashboard + dashboard-setting + user + network + system + record + feature`。
- UI 方向是单页外壳。
- 运行目标优先兼容标准 OpenWrt，而不是仅支持 `fwx` 环境。
- 信息密度采用“总览优先，低频内容折叠或延迟加载”。
- 首页允许直接修改部分高频配置，但不把所有配置都堆进首页。
- 集成方式采用“单页外壳 + 模块化内核”。

## 总体架构

实现拆分为四层。

### 1. 控制器层

文件：

- `luasrc/controller/dashboard.lua`

职责：

- 注册 `/admin/dashboard` 页面入口。
- 对 API 请求做会话校验与鉴权。
- 将 API 请求分发到各功能模块。
- 不再直接承载业务逻辑。

当前控制器已经混合了以下职责：

- 页面渲染
- 本地 API 处理
- 面向 `luci.dashboard.*` 的未来路由加载

第一阶段会将其重构为“薄控制器”，只负责路由和鉴权边界。

### 2. API 层

计划中的模块命名空间：

- `luasrc/dashboard/api/overview.lua`
- `luasrc/dashboard/api/users.lua`
- `luasrc/dashboard/api/network.lua`
- `luasrc/dashboard/api/system.lua`
- `luasrc/dashboard/api/record.lua`
- `luasrc/dashboard/api/feature.lua`
- `luasrc/dashboard/api/settings.lua`

职责：

- 解析请求参数。
- 校验用户输入。
- 调用 service 层。
- 按统一 JSON 格式返回响应。

### 3. Service 层

计划中的模块命名空间：

- `luasrc/dashboard/services/overview.lua`
- `luasrc/dashboard/services/users.lua`
- `luasrc/dashboard/services/network.lua`
- `luasrc/dashboard/services/system.lua`
- `luasrc/dashboard/services/record.lua`
- `luasrc/dashboard/services/feature.lua`
- `luasrc/dashboard/services/settings.lua`

职责：

- 表达 dashboard 级的业务语义。
- 从多个数据源聚合与归一化数据。
- 基于能力探测结果决定功能可用性和降级策略。

示例：

- 将 DHCP lease、ARP、备注配置以及可选的流量数据合并成用户列表。
- 把 `ubus` 和 UCI 的网络状态整理成 dashboard 可读写的网络配置视图。
- 组装首页总览接口的聚合数据。

### 4. Source / Adapter 层

计划中的模块命名空间：

- `luasrc/dashboard/sources/system.lua`
- `luasrc/dashboard/sources/network.lua`
- `luasrc/dashboard/sources/leases.lua`
- `luasrc/dashboard/sources/arp.lua`
- `luasrc/dashboard/sources/nlbwmon.lua`
- `luasrc/dashboard/sources/domains.lua`
- `luasrc/dashboard/sources/feature.lua`
- `luasrc/dashboard/sources/config.lua`

职责：

- 从 OpenWrt 原生能力读取系统状态。
- 读取与写入 dashboard 自己的配置。
- 不承载页面语义或业务聚合逻辑。

### 通用基础层

计划中的公共辅助模块：

- `luasrc/dashboard/http.lua`
- `luasrc/dashboard/response.lua`
- `luasrc/dashboard/session.lua`
- `luasrc/dashboard/validation.lua`
- `luasrc/dashboard/capabilities.lua`

职责：

- 公共 HTTP 辅助
- 统一 JSON 成功/失败响应
- 会话校验
- 参数校验
- 运行时能力探测

## 前端设计

产品仍然是单页，但不再把所有结构、状态和逻辑都塞进一个模板脚本里。

### 单页外壳

主视图文件：

- `luasrc/view/dashboard/main.htm`

重构后的职责：

- 只负责渲染单页外壳。
- 定义固定布局区域。
- 加载共享前端脚本。
- 提供总览区、折叠区、弹层或抽屉容器。

### 前端模块

计划中的静态资源：

- `htdocs/luci-static/dashboard/app.js`
- `htdocs/luci-static/dashboard/sections-overview.js`
- `htdocs/luci-static/dashboard/sections-users.js`
- `htdocs/luci-static/dashboard/sections-network.js`
- `htdocs/luci-static/dashboard/sections-system.js`
- `htdocs/luci-static/dashboard/sections-record.js`
- `htdocs/luci-static/dashboard/sections-feature.js`
- `htdocs/luci-static/dashboard/sections-settings.js`

职责：

- 初始化单页外壳。
- 按模块拉取数据。
- 各自负责渲染与交互。
- 在合适的场景下支持首次展开才加载。

这样可以保持“单页体验”，但不保留当前 `main.htm` 的单文件巨型实现方式。

## 单页布局

页面组织方式采用“总览优先，其余模块按频率和重量分层展示”。

### 顶部总览区

首屏固定展示：

- 系统摘要
- 网络状态
- 实时流量
- 在线设备
- 活跃域名

这一部分继续作为首页第一屏核心区域。

### 用户中心

在单页内展示：

- 分页用户/设备表格
- 在线状态
- 当前速率
- 今日流量
- 常用应用
- 当前域名或 URL
- 备注编辑

用户详情在第一阶段不再跳转独立页面，而是在当前单页中通过抽屉或弹层打开，内部保留标签页：

- 基本信息
- 应用统计
- 今日流量
- 今日 Top Apps
- 访问记录

### 网络设置

作为一个功能区展示，其中包含三个可折叠子面板：

- LAN
- WAN
- 工作模式

首页只开放高频配置项。

### 系统设置

第一阶段只开放直接影响 dashboard 数据正确性的配置，优先包括：

- `lan_ifname`

### 记录设置

首页内开放：

- 启用开关
- 保留时长
- 应用有效时长
- 历史数据大小
- 历史数据路径
- 清理历史数据

### 特征库

首页内展示：

- 当前版本
- 格式
- 应用数量
- 特征分类列表
- 上传入口
- 升级状态

### Dashboard 设置

首页内展示：

- 监控接口或监控设备选择

## 第一阶段允许直接写入的配置

第一阶段只允许从单页写入以下配置。

### Dashboard 设置

- `monitor_device`

### 网络设置

- LAN 协议与地址配置
- LAN DNS
- LAN DHCP 配置
- WAN 协议与地址配置
- WAN PPPoE 账号密码
- dashboard 自己维护的 `work_mode`

### 系统设置

- `lan_ifname`

### 记录设置

- `enable`
- `record_time`
- `app_valid_time`
- `history_data_size`
- `history_data_path`
- `clean_all_data`

### 特征库

- 上传特征包
- 查询升级状态

## API 设计

第一阶段所有 API 统一收敛到一个根路径下：

- `/admin/dashboard/api/`

### 返回格式

成功：

```json
{
  "ok": true,
  "data": {},
  "meta": {}
}
```

失败：

```json
{
  "ok": false,
  "error": {
    "code": "invalid_arg",
    "message": "invalid IPv4 address"
  }
}
```

这会替代当前散乱的返回形式，包括原始 JSON 对象、`code=2000` 和各类不一致的 fallback 数据。

### 第一阶段接口

总览：

- `GET /admin/dashboard/api/overview`

用户：

- `GET /admin/dashboard/api/users`
- `GET /admin/dashboard/api/users/detail?mac=AA%3ABB%3ACC%3ADD%3AEE%3AFF`
- `POST /admin/dashboard/api/users/nickname`

网络：

- `GET /admin/dashboard/api/network/lan`
- `POST /admin/dashboard/api/network/lan`
- `GET /admin/dashboard/api/network/wan`
- `POST /admin/dashboard/api/network/wan`
- `GET /admin/dashboard/api/network/work-mode`
- `POST /admin/dashboard/api/network/work-mode`

系统：

- `GET /admin/dashboard/api/system/config`
- `POST /admin/dashboard/api/system/config`

记录：

- `GET /admin/dashboard/api/record/base`
- `POST /admin/dashboard/api/record/base`
- `POST /admin/dashboard/api/record/action`

特征库：

- `GET /admin/dashboard/api/feature/info`
- `GET /admin/dashboard/api/feature/classes`
- `POST /admin/dashboard/api/feature/upload`
- `GET /admin/dashboard/api/feature/status`

Dashboard 设置：

- `GET /admin/dashboard/api/settings/dashboard`
- `POST /admin/dashboard/api/settings/dashboard`

### 总览聚合接口

总览接口采用聚合设计。

它会一次返回：

- 系统摘要
- 网络摘要
- 流量摘要
- 设备摘要
- 域名摘要
- 能力标记

示例结构：

```json
{
  "ok": true,
  "data": {
    "system": {},
    "network": {},
    "traffic": {},
    "devices": [],
    "domains": {},
    "capabilities": {
      "nlbwmon": true,
      "domain_logs": true,
      "feature_library": false
    }
  }
}
```

这样做可以减少首页首屏请求扇出，方便前端基于能力标记做统一渲染和降级。

## 标准 OpenWrt 下的数据来源

第一阶段明确以标准 OpenWrt 为目标环境，而不是默认假设 `fwx` 存在。

### 系统数据

来源：

- `ubus system board`
- `/proc/uptime`
- `/proc/meminfo`
- `/sys/class/thermal/*`
- 当前 `dashboard.lua` 中已经存在的机型、固件和温度探测逻辑

### 网络数据

来源：

- `ubus network.interface.* status`
- `ubus network.interface dump`
- `uci network`
- `uci dhcp`

### 设备和用户数据

来源：

- `/tmp/dhcp.leases`
- `/proc/net/arp`
- dashboard 自己维护的备注存储
- 可选的 `nlbwmon` 流量补充数据

### 域名活跃数据

优先级顺序：

1. OpenClash 日志
2. `logread` 中的 `dnsmasq` 日志
3. 无可用数据源

### 特征库

第一阶段不再把 `/etc/fwxd/feature.cfg` 当作权威存储。

它会改成 dashboard 自己管理特征文件和元数据，使特征库模块可以在没有 `fwx` 的环境中独立存在。

原始 `fwx_feature` 实现会写入：

- `/etc/fwxd/feature.cfg`
- `/www/luci-static/resources/app_icons/`
- 并向 `fwxd` 进程发信号

第一阶段会用 dashboard 自己的存储路径和状态管理来替代这套做法。

### 记录数据

原始 `fwx_record` 依赖 `fwx` 后端 API。

第一阶段会把记录功能重定义为 dashboard 自己的历史快照与配置体系，而不是伪装成 `fwx` 后端仍然存在。

## Dashboard 自有持久化

第一阶段引入 dashboard 自己管理的配置和运行时存储。

### 持久化 UCI

新的 UCI 配置命名空间：

- `dashboard`

初始持久字段包括：

- `monitor_device`
- `lan_ifname`
- `work_mode`
- 记录模块相关配置
- 备注映射
- 特征库所需元数据

### 运行时缓存

临时运行数据目录：

- `/tmp/dashboard`

### 历史数据目录

用于记录和历史快照：

- 存储在配置指定的 `history_data_path`

第一阶段历史格式保持简单：

- JSON 或 JSONL 快照

本阶段不引入嵌入式数据库。

## 能力探测与降级策略

明确降级能力是第一阶段的硬要求。

### 缺少 `nlbwmon`

- 设备列表仍然可用。
- 用户流量排行和按用户细化的流量统计不可用。
- UI 必须显示明确降级提示，不能空白，也不能默认 500。

### 缺少可用域名日志

- 域名模块仍然展示。
- UI 需要提示当前运行环境没有可用域名观测源。

### 尚未上传特征包

- 特征库模块仍然可用。
- 展示空状态和上传入口。

### 无法使用历史数据路径

- 记录模块仍可展示当前配置。
- 持久化历史能力需要被禁用或显示为不可用。

### 工作模式语义

在标准 OpenWrt 上，`work_mode` 被视为 dashboard 自己的行为和展示语义配置。

它不宣称能够像 `fwx` 后端那样真实改变数据平面行为。

### 用户与应用识别限制

第一阶段不承诺提供 `fwx` 级别的应用识别精度。

凡是原始 `fwx` 页面依赖深度内核辅助应用识别的地方，第一阶段只能提供尽力而为的近似结果，或者明确显示能力缺失。

## 错误处理

### 输入校验

校验逻辑统一收口到公共辅助模块。

需要校验的字段包括：

- IPv4 地址
- 子网掩码
- 网关
- DNS 地址
- PPPoE 凭据
- LAN 接口名
- 特征包上传格式和大小
- 记录模块的历史数据大小与路径

### 危险操作

以下操作必须提供明确警告：

- 修改 LAN IP
- 任何可能导致当前管理连接断开的操作
- 清理历史数据

### 长耗时操作

以下动作必须提供可见状态反馈，并且不能卡死整页：

- 特征包上传、解压与校验
- LAN 重配置后的等待提示
- 记录数据清理

## 测试策略

第一阶段测试分为解析逻辑检查、打包集成检查和功能验收三层。

### 解析与逻辑检查

需要为以下能力增加可测试的辅助逻辑或针对性测试：

- DHCP lease 解析
- ARP + lease + nickname 合并
- 域名日志解析
- LAN/WAN 输入校验
- 特征库元数据校验

### 集成验证

- 对所有新增 Lua 模块做语法检查
- 对新增前端脚本做 JavaScript 语法检查
- 通过现有 OpenWrt SDK 工作流验证打包

当前 `.github/workflows/release.yml` 里的打包流程必须继续能为 `luci-app-dashboard` 产出可安装的 IPK。

### 功能验收

验收标准包括：

- `/admin/dashboard` 在标准 OpenWrt 上可以正常打开。
- 可选能力缺失时不会导致页面渲染失败。
- 首页总览数据可以正常刷新。
- 用户列表可以渲染，备注编辑可以工作。
- 用户详情抽屉或弹层可以打开并加载对应数据。
- LAN/WAN/系统/记录/Dashboard 设置可以正常读写，并带有明确的校验与错误提示。
- 特征包上传能正确处理成功、格式错误和超大文件。
- 所有能力缺失都表现为“可见降级”，而不是空白页或默认 500。

## 完成定义

当以下条件全部满足时，第一阶段视为完成：

- `luci-app-dashboard` 仍然保持单页 dashboard 入口。
- 第一阶段范围内的 `fwx` 功能已经并入这个单页。
- 实现已经不再依赖 `fwxd` 或 `kmod-fwx`。
- 后端代码已经拆成控制器、API、service 和 source 层。
- 前端代码已经拆成单页外壳和功能模块。
- 插件在标准 OpenWrt 上可以运行，并具备明确降级能力。
- 现有 CI 仍能打包出可安装的 IPK。

## 风险

### 1. 再次变成单体

如果重构做了一半停住，`dashboard.lua` 和 `main.htm` 会变得比现在更大、更难维护。

缓解方式：

- 先拆路由
- 再拆 service
- 尽早把前端区块逻辑迁到独立静态模块

### 2. 对 `fwx` 能力的错误等价

原始页面中有些能力在普通 OpenWrt 上并不存在等价后端语义。

缓解方式：

- 明确能力标记
- 不伪造深度应用识别
- 对不支持项做显式降级

### 3. 特征包上传与 `fwx` 的耦合

原始特征包上传路径与 `fwxd` 强耦合。

缓解方式：

- 改用 dashboard 自己的存储位置和状态逻辑
- 把上传校验做成自包含实现

### 4. 单页复杂度过高

单页本身也可能变得太重。

缓解方式：

- 使用折叠区
- 低频模块延迟加载
- 重内容详情用抽屉或弹层承载

## 推荐实施顺序

建议按以下顺序推进第一阶段实现：

1. 引入公共 response、session、validation 和 capability 辅助模块。
2. 将 `dashboard.lua` 的路由重构为模块分发。
3. 引入 dashboard 自己的配置存储。
4. 实现 overview 和 capability 相关 API。
5. 提取单页外壳与前端功能模块。
6. 实现用户列表和用户详情能力。
7. 实现网络和系统可写模块。
8. 实现基于 dashboard 自有持久化的记录能力。
9. 实现特征库存储、上传与分类展示。
10. 完成降级态收口与验收验证。
