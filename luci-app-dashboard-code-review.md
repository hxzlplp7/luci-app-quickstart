# luci-app-dashboard 代码审查结论

审查对象：`luci-app-dashboard.zip`

## 结论

该项目能跑起来的主体框架基本完整，但存在几处明显的功能性 bug 和安全性问题，建议优先修复：

1. OAF 子接口桥接函数名写错，导致前端请求 `/admin/dashboard/api/oaf/status` 和 `/admin/dashboard/api/oaf/upload` 时可能落到“endpoint not found”。
2. 上传接口缺少 CSRF Token 校验，且文件大小限制是在写完整个临时文件后才校验，存在伪造请求和磁盘/内存占满风险。
3. `read_ipv4_from_device()` 直接拼接网卡名进入 shell 命令，存在命令注入风险。
4. `sys-hostname` 前后端字段不一致，页面把“主机名”显示成了“设备型号”。
5. 页面文案写“今日上传/下载”，但后端返回的是累计接口计数器；同时计数器回绕后会出现负速率。
6. OAF 设备统计按访问记录累加，不是按唯一设备计数，数据会偏大；分类分布图也没有真正使用后端返回数据。

## 已生成补丁

- `luci-app-dashboard-fixes.patch`

## 补丁包含的修复

### 1. 修复 OAF 路由桥接

修改文件：`luasrc/controller/dashboard.lua`

把：

```lua
if sub == "status" and type(oaf.api_oaf_status) == "function" then
    return oaf.api_oaf_status()
elseif sub == "upload" and type(oaf.api_oaf_upload) == "function" then
    return oaf.api_oaf_upload()
end
```

改为：

```lua
if sub == "status" and type(oaf.action_status) == "function" then
    return oaf.action_status()
elseif sub == "upload" and type(oaf.action_upload) == "function" then
    return oaf.action_upload()
end
```

并在 `luasrc/controller/api/oaf.lua` 中补充兼容别名：

```lua
M.api_oaf_status = M.action_status
M.api_oaf_upload = M.action_upload
```

### 2. 修复上传接口安全问题

修改文件：`luasrc/controller/api/oaf.lua`

补丁做了这些事：

- 只允许 POST；
- 校验 `token` 是否等于 `luci.dispatcher.context.authtoken`；
- 在流式接收 chunk 时实时统计大小，超过 `MAX_SIZE` 立即停止写入；
- 临时文件创建失败时直接返回错误。

### 3. 修复 shell 命令注入风险

修改文件：`luasrc/controller/dashboard.lua`

把：

```lua
local s = exec_trim("ip -4 addr show dev " .. dev .. " 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1")
```

改为：

```lua
dev = trim(dev)
if dev == "" then return "" end
local s = exec_trim("ip -4 addr show dev " .. shell_quote(dev) .. " | awk '/inet / {print $2; exit}' | cut -d/ -f1")
```

### 4. 修复主机名显示错误

后端 `api_sysinfo()` 新增 `hostname` 字段，前端从 `data.hostname` 读取，不再错误使用 `data.model`。

### 5. 修复流量显示语义和负值问题

修改文件：`luasrc/view/dashboard/main.htm`

- “今日下载/今日上传” 改为 “累计下载/累计上传”；
- `refreshTraffic()` 增加计数器回绕/重置保护；
- 首次加载时立即执行 `refreshTraffic()`，避免一开始长期显示 `-`。

### 6. 修复 OAF 统计不准

修改文件：`luasrc/controller/api/oaf.lua`

- 设备数改为按唯一 MAC 统计，而不是按 visit 记录数累加；
- `collect_device_macs()` 的 fallback 分支返回正确的 `devs = list`；
- 前端 APP 分类图改为真正使用后端返回的 `class_stats`。

### 7. 修复前后端文件类型校验不一致

前端原本允许 `.dat`，但后端实际逻辑围绕 `.bin` / `.zip` 展开，因此补丁将前端校验收紧为 `.bin|.zip`。

## 应用补丁示例

```bash
cd /path/to/luci-app-dashboard
patch -p0 < /path/to/luci-app-dashboard-fixes.patch
```

## 说明

这次是静态审查 + 补丁生成，没有在真实 OpenWrt / LuCI 运行环境里做联调验证；当前容器里也没有 Lua 解释器可用，无法做 `luac` 语法检查。
