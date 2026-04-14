-- Dashboard API Logic
-- 专注于高性能实时数据获取，移除冗余代码

local u = require "luci.dashboard.util"
local util = require "luci.util"
local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"

local M = {}

-- 流量统计缓存
local TRAFFIC_STATE_FILE = "/tmp/dashboard_traffic.json"
local TRAFFIC_SLOTS = 20

--- 获取系统状态（CPU, 内存, 负载）
function M.get_system_status()
    local result = {}
    local uptime_str = u.read_file("/proc/uptime") or "0"
    result.uptime = math.floor(tonumber(uptime_str:match("^(%S+)")) or 0)

    local loadavg = u.read_file("/proc/loadavg") or "0 0 0"
    local load1 = tonumber(loadavg:match("^(%S+)")) or 0

    local cpus = 0
    local cpuinfo = u.read_file_all("/proc/cpuinfo") or ""
    for _ in cpuinfo:gmatch("processor%s*:") do cpus = cpus + 1 end
    if cpus == 0 then cpus = 1 end
    result.cpu_usage = math.min(100, math.floor(load1 * 100 / cpus))

    local meminfo = u.read_file_all("/proc/meminfo") or ""
    local m_total = tonumber(meminfo:match("MemTotal:%s+(%d+)")) or 1
    local m_free = tonumber(meminfo:match("MemFree:%s+(%d+)")) or 0
    local m_avail = tonumber(meminfo:match("MemAvailable:%s+(%d+)")) or m_free
    result.mem_usage = math.floor(((m_total - m_avail) * 100) / m_total)

    u.json_success(result)
end

--- 获取网络基础信息 (WAN/IP)
function M.get_network_status()
    local result = {}
    local status = util.ubus("network.interface.wan", "status") or {}
    
    result.ip = (status["ipv4-address"] and status["ipv4-address"][1]) and status["ipv4-address"][1].address or "N/A"
    result.proto = status.proto or "unknown"
    
    -- 公网 IP 缓存
    local f = io.open("/tmp/public_ip.txt", "r")
    if f then
        result.public_ip = f:read("*a"):gsub("%s+$", "")
        f:close()
    else
        result.public_ip = "Detecting..."
    end

    u.json_success(result)
end

--- 获取实时网速与深度统计 (基于 nlbwmon)
function M.get_traffic()
    -- 1. 获取基础物理接口流量（用于最精准实时网速）
    local wan_status = util.ubus("network.interface.wan", "status") or {}
    local dev = wan_status.l3_device or wan_status.device or "eth0"
    local rx_bytes = tonumber(u.read_file("/sys/class/net/" .. dev .. "/statistics/rx_bytes")) or 0
    local tx_bytes = tonumber(u.read_file("/sys/class/net/" .. dev .. "/statistics/tx_bytes")) or 0
    local now = os.time()

    -- 2. 读取 nlbwmon 统计数据 (域名与协议)
    local nlbw_data = jsonc.parse(u.exec("nlbw -c json 2>/dev/null") or "[]") or {}
    
    local domains = {}
    local types = {}
    local total_rx = 0
    local total_tx = 0

    for _, entry in ipairs(nlbw_data) do
        local rx = tonumber(entry.rx_bytes) or 0
        local tx = tonumber(entry.tx_bytes) or 0
        total_rx = total_rx + rx
        total_tx = total_tx + tx

        -- 域名/主机统计
        local host = entry.hostname or entry.ip or "Unknown"
        if host ~= "" then
            domains[host] = (domains[host] or 0) + rx + tx
        end

        -- 流量类型统计 (以协议/服务为准)
        local family = entry.family or "Other"
        types[family] = (types[family] or 0) + rx + tx
    end

    -- 排序 Top 5 域名
    local sorted_domains = {}
    for k, v in pairs(domains) do table.insert(sorted_domains, {name = k, value = v}) end
    table.sort(sorted_domains, function(a, b) return a.value > b.value end)
    local top_domains = {}
    for i = 1, math.min(5, #sorted_domains) do table.insert(top_domains, sorted_domains[i]) end

    -- 流量类型分布
    local type_dist = {}
    for k, v in pairs(types) do table.insert(type_dist, {name = k, value = v}) end

    -- 3. 计算实时速率
    local raw = u.read_file_all(TRAFFIC_STATE_FILE)
    local state = raw and jsonc.parse(raw) or { items = {} }
    local items = state.items or {}
    local speed_rx = 0
    local speed_tx = 0

    if state.time and now > state.time then
        local dt = now - state.time
        speed_rx = math.max(0, (rx_bytes - (state.rx or 0)) / dt)
        speed_tx = math.max(0, (tx_bytes - (state.tx or 0)) / dt)
        
        table.insert(items, {time = now, rx = speed_rx, tx = speed_tx})
        if #items > TRAFFIC_SLOTS then table.remove(items, 1) end
    end

    u.write_to_file(TRAFFIC_STATE_FILE, jsonc.stringify({
        time = now, rx = rx_bytes, tx = tx_bytes, items = items
    }))

    u.json_success({
        speed = { rx = speed_rx, tx = speed_tx },
        history = items,
        top_domains = top_domains,
        traffic_types = type_dist,
        totals = { rx = total_rx, tx = total_tx }
    })
end

return M
