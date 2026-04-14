module("luci.controller.dashboard", package.seeall)

function index()
    entry({"admin", "dashboard"}, firstchild(), "Dashboard", 10).dependent = true
    
    entry({"admin", "dashboard", "api", "sysinfo"}, call("api_sysinfo"))
    entry({"admin", "dashboard", "api", "netinfo"}, call("api_netinfo"))
    entry({"admin", "dashboard", "api", "traffic"}, call("api_traffic"))
    entry({"admin", "dashboard", "api", "devices"}, call("api_devices"))
    entry({"admin", "dashboard", "api", "domains"}, call("api_domains"))
end

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local sys = require "luci.sys"
local util = require "luci.util"

local function send_json(data)
    http.prepare_content("application/json")
    http.write(jsonc.stringify(data or {}))
end

-- 格式化时间，保留秒数，并将单位国际化
local function format_time(seconds)
    if not seconds then return "-" end
    seconds = tonumber(seconds)
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    
    -- 使用英文格式，中文由 PO 文件翻译整个字符串（如果需要）或直接返回
    return string.format("%dd %dh %dm %ds", days, hours, mins, secs)
end

function api_sysinfo()
    local meminfo = sys.memory()
    local loadavg = sys.loadavg()
    local uptime = sys.uptime()
    
    -- 优化：优先使用 ubus 获取准确的设备型号
    local boardinfo = util.ubus("system", "board", {})
    local model = ""
    if boardinfo and boardinfo.model then
        model = boardinfo.model
    else
        model = util.trim(sys.exec("cat /tmp/sysinfo/model 2>/dev/null"))
    end
    if not model or model == "" then model = "Generic Device" end
    
    local mem_usage = 0
    if meminfo.total > 0 then
        mem_usage = math.floor(((meminfo.total - meminfo.free) / meminfo.total) * 100)
    end
    
    local cpu_usage = math.min(math.floor(loadavg[1] * 100), 100)

    send_json({
        model = model,
        sysUptime = format_time(uptime),
        cpuUsage = cpu_usage,
        memUsage = mem_usage
    })
end

function api_netinfo()
    local wanIp = "-"
    local wanStatus = "down"
    local lanIp = "-"
    local networkUptimeStr = "-"
    
    local wan_stat = util.ubus("network.interface.wan", "status", {})
    if wan_stat and wan_stat.up then
        wanStatus = "up"
        networkUptimeStr = format_time(wan_stat.uptime)
        if wan_stat["ipv4-address"] and #wan_stat["ipv4-address"] > 0 then
            wanIp = wan_stat["ipv4-address"][1].address
        end
    end

    local lan_stat = util.ubus("network.interface.lan", "status", {})
    if lan_stat and lan_stat["ipv4-address"] and #lan_stat["ipv4-address"] > 0 then
        lanIp = lan_stat["ipv4-address"][1].address
    end

    send_json({
        wanStatus = wanStatus,
        wanIp = wanIp,
        lanIp = lanIp,
        networkUptime = networkUptimeStr
    })
end

function api_traffic()
    local wan_dev = util.trim(sys.exec("uci get network.wan.device 2>/dev/null") or "eth0")
    if wan_dev == "" then wan_dev = "eth0" end
    
    local rx_bytes = tonumber(util.trim(sys.exec("cat /sys/class/net/"..wan_dev.."/statistics/rx_bytes 2>/dev/null"))) or 0
    local tx_bytes = tonumber(util.trim(sys.exec("cat /sys/class/net/"..wan_dev.."/statistics/tx_bytes 2>/dev/null"))) or 0

    send_json({
        rx_bytes = rx_bytes,
        tx_bytes = tx_bytes
    })
end

function api_devices()
    local devices = {}
    local leases = util.execl("cat /tmp/dhcp.leases 2>/dev/null")
    local arp = util.execl("cat /proc/net/arp 2>/dev/null")
    
    local active_macs = {}
    for _, line in ipairs(arp) do
        local ip, type, flags, mac = line:match("^([%d%.]+)%s+%S+%s+0x(%d+)%s+([%x%:]+)")
        if mac and flags ~= "0" then 
            active_macs[mac:lower()] = true 
        end
    end

    for _, line in ipairs(leases) do
        local ts, mac, ip, name = line:match("^(%d+)%s+([%x%:]+)%s+([%d%.]+)%s+([^%s]+)")
        if mac then
            local is_active = active_macs[mac:lower()] == true
            local dev_type = "other"
            if name:lower():match("iphone") or name:lower():match("android") or name:lower():match("phone") then
                dev_type = "mobile"
            elseif name:lower():match("macbook") or name:lower():match("pc") or name:lower():match("laptop") then
                dev_type = "laptop"
            end

            table.insert(devices, {
                mac = mac:upper(),
                ip = ip,
                name = (name == "*" and "Unknown" or name),
                type = dev_type,
                active = is_active
            })
        end
    end
    send_json(devices)
end

function api_domains()
    local result = {}
    
    local handle = io.popen("nlbwmon -c /etc/config/nlbwmon --dump -f json 2>/dev/null")
    if handle then
        local raw_json = handle:read("*a")
        handle:close()

        if raw_json and raw_json ~= "" then
            local success, parsed_data = pcall(jsonc.parse, raw_json)
            
            if success and parsed_data and parsed_data.connections then
                local domain_counts = {}
                local has_data = false
                
                for _, conn in ipairs(parsed_data.connections) do
                    local domain = conn.hostname or conn.dst_ip
                    if domain and domain ~= "" and domain ~= "-" then
                        local count = tonumber(conn.conns) or 1 
                        domain_counts[domain] = (domain_counts[domain] or 0) + count
                        has_data = true
                    end
                end

                if has_data then
                    for domain, count in pairs(domain_counts) do
                        if not domain:match("^192%.168%.") and not domain:match("^10%.") then
                            table.insert(result, { domain = domain, count = count })
                        end
                    end

                    table.sort(result, function(a, b) return a.count > b.count end)
                    
                    local top10 = {}
                    for i = 1, math.min(10, #result) do
                        table.insert(top10, result[i])
                    end
                    
                    send_json(top10)
                    return
                end
            end
        end
    end

    send_json({})
end
