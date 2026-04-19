-- Dashboard Controller
-- entry({"admin","dashboard"}) → dashboard_dispatch()
--   → renders main.htm  OR  serves 5 local JSON APIs consumed by main.htm
-- entry({"dashboard-api"})     → dashboard_api()
--   → Vue-bundle API gateway (api_network / api_system / api_guide / api_nas)

local http       = require "luci.http"
local util       = require "luci.util"
local jsonc      = require "luci.jsonc"
local d          = require "luci.dispatcher"
local fs         = require "nixio.fs"
local _          = require "luci.i18n".translate

-- 定义模块表 (兼容 Lua 5.1/5.4)
local M = {}

function M.index()
    d.entry({ "admin", "dashboard" }, d.call("dashboard_dispatch"), _("Dashboard"), 0).leaf = true
    d.entry({ "admin", "dashboard", "api" }, d.call("dashboard_dispatch")).leaf = true
end

-- =====================================================================
-- Session Validation
-- =====================================================================

local function check_session()
    local sdat, sid
    for _, key in ipairs({ "sysauth_https", "sysauth_http", "sysauth" }) do
        sid = http.getcookie(key)
        if sid then
            sdat = util.ubus("session", "get", { ubus_rpc_session = sid })
            if type(sdat) == "table" and
                type(sdat.values) == "table" and
                type(sdat.values.token) == "string" then
                return sid, sdat.values
            end
        end
    end
    return nil, nil
end

-- =====================================================================
-- Tiny I/O helpers (no external deps)
-- =====================================================================

local function read_line(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l"); f:close(); return v
end

local function read_all(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*a"); f:close(); return v
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function exec_trim(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return "" end
    local out = p:read("*a") or ""; p:close()
    return out:gsub("%s+$", "")
end

local function shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", [['"'"']]) .. "'"
end

local function path_exists(p)
    local f = io.open(p, "r")
    if f then
        f:close(); return true
    end
    return false
end

local function read_conntrack_count()
    local direct = tonumber(trim(read_line("/proc/sys/net/netfilter/nf_conntrack_count") or ""))
    if direct then
        return direct
    end

    local from_tool = tonumber(exec_trim("conntrack -C"))
    if from_tool then
        return from_tool
    end

    local from_proc = tonumber(exec_trim("wc -l </proc/net/nf_conntrack"))
    if from_proc then
        return from_proc
    end

    return 0
end

local function first_ipv4_address(status)
    if type(status) ~= "table" then
        return ""
    end

    local list = status["ipv4-address"] or {}
    if type(list) == "table" and type(list[1]) == "table" then
        return trim(list[1].address or "")
    end

    return trim(status.ipaddr or "")
end

local function to_array(value)
    if type(value) ~= "table" then
        return {}
    end

    if value[1] ~= nil then
        return value
    end

    local result = {}
    for _, item in pairs(value) do
        result[#result + 1] = item
    end
    return result
end

local function has_default_route(status)
    if type(status) ~= "table" then
        return false
    end

    for _, route in ipairs(to_array(status.route or status.routes or {})) do
        local r = type(route) == "table" and route or {}
        local target = trim(r.target or "")
        local mask = tonumber(r.mask)
        if target == "0.0.0.0" or target == "::" or target == "::/0" or mask == 0 then
            return true
        end
    end

    return false
end

local function read_ipv4_from_device(dev)
    dev = trim(dev)
    if dev == "" then return "" end
    local s = exec_trim("ip -4 addr show dev " .. shell_quote(dev) .. " | awk '/inet / {print $2; exit}' | cut -d/ -f1")
    return s
end

local function proactive_ping_check()
    local ok = os.execute("ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1")
    if ok == 0 or ok == true then return true end

    ok = os.execute("ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1")
    if ok == 0 or ok == true then return true end

    ok = os.execute("nslookup www.baidu.com 223.5.5.5 >/dev/null 2>&1")
    if ok == 0 or ok == true then return true end

    ok = os.execute("wget -q --spider -T 2 http://connectivitycheck.platform.hicloud.com/generate_204 >/dev/null 2>&1")
    if ok == 0 or ok == true then return true end

    return false
end

local function read_default_route_device()
    local dev = exec_trim("ip route show default | awk 'NR==1 {print $5}'")
    if dev ~= "" then
        return dev
    end

    return exec_trim("ip -6 route show default | awk 'NR==1 {print $5}'")
end

local function read_default_route_gateway()
    local gw = exec_trim("ip route show default | awk 'NR==1 {print $3}'")
    if gw ~= "" then
        return gw
    end

    return exec_trim("ip -6 route show default | awk 'NR==1 {print $3}'")
end

local function resolve_lan_ip(uci)
    local lan_status = util.ubus("network.interface.lan", "status", {}) or {}
    local lan_ip = first_ipv4_address(lan_status)
    if lan_ip ~= "" then
        return lan_ip
    end

    lan_ip = trim(uci:get("network", "lan", "ipaddr") or "")
    if lan_ip ~= "" then
        return lan_ip
    end

    local lan_device = trim(uci:get("network", "lan", "device") or uci:get("network", "lan", "ifname") or "br-lan")
    lan_ip = read_ipv4_from_device(lan_device)
    if lan_ip ~= "" then
        return lan_ip
    end

    return read_ipv4_from_device("br-lan")
end

local function resolve_uplink_status()
    local dump = util.ubus("network.interface", "dump", {}) or {}
    local interfaces = to_array(dump.interface or dump.interfaces or {})
    local default_dev = read_default_route_device()
    local best_name = "wan"
    local best = util.ubus("network.interface.wan", "status", {}) or {}
    if type(best) ~= "table" then
        best = {}
    end
    local best_score = -1

    local function score_interface(name, status)
        local s = type(status) == "table" and status or {}
        local score = 0
        local ipaddr = first_ipv4_address(s)
        local dev = trim(s.l3_device or s.device or "")

        if name == "wan" then
            score = score + 60
        end
        if name == "lan" then
            score = score - 5
        end
        if s.up == true then
            score = score + 40
        end
        if ipaddr ~= "" then
            score = score + 25
        end
        if has_default_route(s) then
            score = score + 45
        end
        if default_dev ~= "" and dev == default_dev then
            score = score + 80
        end

        return score
    end

    best_score = score_interface(best_name, best)

    for _, item in ipairs(interfaces) do
        local s = type(item) == "table" and item or nil
        local name = trim(s and s.interface or "")
        if s and name ~= "" and name ~= "loopback" then
            local score = score_interface(name, s)
            if score > best_score then
                best = s
                best_name = name
                best_score = score
            end
        end
    end

    local wan_ip = first_ipv4_address(best)
    if wan_ip == "" then
        wan_ip = read_ipv4_from_device(best.l3_device or best.device or default_dev)
    end

    -- 2. 联网探测：分层校验法
    local is_online = false
    if best.up then
        -- 复用 proactive_ping_check()，兼容 Lua 5.1 (返回0) 和 Lua 5.3+ (返回true)
        is_online = proactive_ping_check()
    end

    return {
        name = best_name,
        status = best,
        wan_ip = wan_ip,
        online = is_online,
        gateway = read_default_route_gateway(),
        dns = to_array(best and best["dns-server"] or {}),
        uptime = tonumber(best and best.uptime or 0) or 0,
    }
end

local function normalize_domain(domain)
    local value = trim(domain):lower()
    if value == "" then
        return nil
    end

    value = value:gsub("^https?://", "")
    value = value:gsub("^%*%.", "")
    value = value:gsub("/.*$", "")
    value = value:gsub(":.*$", "")
    value = value:gsub("%.+$", "")

    if value == "" or not value:match("%.") then
        return nil
    end

    if not value:match("[%a]") then
        return nil
    end

    if value:match("^%d+%.%d+%.%d+%.%d+$") then
        return nil
    end

    if value:match("in%-addr%.arpa$") or value:match("^localhost$") then
        return nil
    end

    return value
end

local function extract_domains_from_line(line)
    local results = {}
    local seen = {}
    local patterns = {
        "-->%s*([%w%-%.]+)%:%d+",
        "%[DNS%]%s*([%w%-%.]+)",
        "host=([%w%-%.]+)",
        "sni=([%w%-%.]+)",
        "query[%[%]%w]*%s+([%w%-%.]+)%s+from",
        "reply%s+([%w%-%.]+)%s+is",
    }

    for _, pattern in ipairs(patterns) do
        for candidate in tostring(line or ""):gmatch(pattern) do
            local domain = normalize_domain(candidate)
            if domain and not seen[domain] then
                seen[domain] = true
                results[#results + 1] = domain
            end
        end
    end

    for candidate in tostring(line or ""):gmatch("([%w][%w%-]*[%w]?%.[%w%.%-]+)") do
        local domain = normalize_domain(candidate)
        if domain and not seen[domain] then
            seen[domain] = true
            results[#results + 1] = domain
        end
    end

    return results
end

local function collect_domains_from_command(command)
    local domains = {}
    local pipe = io.popen(command .. " 2>/dev/null")
    if not pipe then
        return domains
    end

    for line in pipe:lines() do
        local extracted = extract_domains_from_line(line)
        for _, domain in ipairs(extracted) do
            domains[#domains + 1] = domain
        end
    end

    pipe:close()
    return domains
end

local function collect_domain_source()
    local plugin_sources = {
        { name = "openclash", path = "/tmp/openclash.log", command = "tail -n 1500 /tmp/openclash.log" },
        { name = "passwall", path = "/tmp/log/passwall.log", command = "tail -n 1500 /tmp/log/passwall.log" },
        { name = "passwall2", path = "/tmp/log/passwall2.log", command = "tail -n 1500 /tmp/log/passwall2.log" },
        { name = "homeproxy", path = "/tmp/homeproxy.log", command = "tail -n 1500 /tmp/homeproxy.log" },
        { name = "mihomo", path = "/tmp/mihomo.log", command = "tail -n 1500 /tmp/mihomo.log" },
        { name = "sing-box", path = "/tmp/sing-box.log", command = "tail -n 1500 /tmp/sing-box.log" },
    }

    for _, source in ipairs(plugin_sources) do
        if path_exists(source.path) then
            local domains = collect_domains_from_command(source.command)
            if #domains > 0 then
                return source.name, domains
            end
        end
    end

    local direct = collect_domains_from_command("logread | grep -iE 'dnsmasq|smartdns' | tail -n 1500")
    if #direct > 0 then
        return "direct", direct
    end

    return "none", {}
end

-- =====================================================================
-- Local API: sysinfo
-- =====================================================================

local function api_sysinfo()
    local model = ""
    local boardinfo = util.ubus("system", "board", {})
    if type(boardinfo) == "table" and boardinfo.model then model = boardinfo.model end
    if model == "" then model = exec_trim("cat /tmp/sysinfo/model 2>/dev/null") end
    if model == "" then model = exec_trim("cat /proc/device-tree/model 2>/dev/null | tr -d '\\0'") end
    if model == "" then model = "Generic Device" end

    local hostname = ""
    if type(boardinfo) == "table" and boardinfo.hostname then hostname = trim(boardinfo.hostname) end
    if hostname == "" then hostname = trim(read_line("/proc/sys/kernel/hostname") or "") end
    if hostname == "" then hostname = exec_trim("uci -q get system.@system[0].hostname") end

    local release  = read_all("/etc/openwrt_release") or ""
    local firmware = release:match("DISTRIB_DESCRIPTION='([^']*)'")
        or release:match('DISTRIB_DESCRIPTION="([^"]*)"')
        or release:match('DISTRIB_DESCRIPTION=([^%s]*)')
        or "OpenWrt"

    local kernel = read_line("/proc/sys/kernel/osrelease") or "Unknown"

    local temp = 0
    for i = 0, 9 do
        local raw = tonumber(read_line("/sys/class/thermal/thermal_zone" .. i .. "/temp") or "")
        if raw then
            if raw > 1000 then
                temp = math.floor(raw / 1000)
                break
            elseif raw > 0 then
                temp = raw
                break
            end
        end
    end

    -- CPU 使用率：跨请求差分采样法，利用轮询间隔（10s）作为采样窗口
    local CPU_STATE_FILE = "/tmp/.dashboard_cpu_state"

    local function get_cpu_jiffies()
        local stat = fs.readfile("/proc/stat")
        if stat then
            local user, nice, system, idle, iowait, irq, softirq = stat:match("cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
            if user then
                local total = user + nice + system + idle + iowait + irq + softirq
                local busy = total - idle
                return total, busy
            end
        end
        return 0, 0
    end

    local cpuUsage = 0
    local t_now, b_now = get_cpu_jiffies()

    local prev_state = read_line(CPU_STATE_FILE)
    if prev_state then
        local t_prev, b_prev = prev_state:match("^(%d+)%s+(%d+)")
        t_prev = tonumber(t_prev) or 0
        b_prev = tonumber(b_prev) or 0
        if t_now > t_prev then
            cpuUsage = math.floor(((b_now - b_prev) / (t_now - t_prev)) * 100)
            if cpuUsage < 0 then cpuUsage = 0 end
            if cpuUsage > 100 then cpuUsage = 100 end
        end
    end

    local sf = io.open(CPU_STATE_FILE, "w")
    if sf then
        sf:write(tostring(t_now) .. " " .. tostring(b_now))
        sf:close()
    end

    local ustr       = read_line("/proc/uptime") or "0"
    local uptime_raw = math.floor(tonumber(ustr:match("^(%S+)")) or 0)

    local lavg       = read_line("/proc/loadavg") or "0"
    local load1      = tonumber(lavg:match("^(%S+)")) or 0
    -- 此处已移除冗余的 cpuUsage 覆盖逻辑，直接使用上方计算出的真实使用率

    local meminfo  = read_all("/proc/meminfo") or ""
    local mem      = {}
    for k, v in meminfo:gmatch("(%S+):%s+(%d+)") do
        mem[k] = tonumber(v)
    end
    local mt       = mem.MemTotal or 1
    local ma       = mem.MemAvailable or mem.MemFree or 0
    local memUsage = math.floor((mt - ma) * 100 / mt)

    local hasSamba4 = path_exists("/usr/lib/lua/luci/controller/samba4.lua") or path_exists("/etc/config/samba4")

    http.prepare_content("application/json")
    http.write(jsonc.stringify({
        hostname    = hostname,
        model       = model,
        firmware    = firmware,
        kernel      = kernel,
        temp        = temp,
        systime_raw = os.time(),
        uptime_raw  = uptime_raw,
        cpuUsage    = cpuUsage,
        memUsage    = memUsage,
        samba       = hasSamba4,
    }))
end

-- =====================================================================
-- Local API: netinfo
-- =====================================================================

local function api_netinfo()
    local uci = require("luci.model.uci").cursor()
    local ok_uplink, uplink = pcall(resolve_uplink_status)
    if not ok_uplink or type(uplink) ~= "table" then
        local default_dev = read_default_route_device()
        local fallback_wan = read_ipv4_from_device(default_dev)
        if fallback_wan == "" then
            fallback_wan = exec_trim("ip -4 addr show scope global | awk '/inet / && $NF != \"lo\" {print $2; exit}' | cut -d/ -f1")
        end

        uplink = {
            name = default_dev ~= "" and default_dev or "wan",
            wan_ip = fallback_wan,
            online = default_dev ~= "" or fallback_wan ~= "",
            dns = {},
            uptime = 0,
            gateway = read_default_route_gateway(),
        }
    end

    local ok_lan, lan_ip = pcall(resolve_lan_ip, uci)
    if not ok_lan or trim(lan_ip or "") == "" then
        lan_ip = trim(uci:get("network", "lan", "ipaddr") or "")
        if lan_ip == "" then
            lan_ip = read_ipv4_from_device("br-lan")
        end
    end

    http.prepare_content("application/json")
    http.write(jsonc.stringify({
        wanStatus          = uplink.online and "up" or "down",
        wanIp              = uplink.wan_ip,
        lanIp              = lan_ip,
        dns                = uplink.dns,
        network_uptime_raw = uplink.uptime,
        connCount          = read_conntrack_count(),
        interfaceName      = uplink.name,
        gateway            = uplink.gateway,
    }))
end

-- =====================================================================
-- Local API: traffic
-- =====================================================================

local function api_traffic()
    local wan   = util.ubus("network.interface.wan", "status") or {}
    local l3dev = wan.l3_device or wan.device or ""

    if l3dev == "" then
        local dump = util.ubus("network.interface", "dump", {}) or {}
        for _, e in ipairs(dump.interface or dump.interfaces or {}) do
            local n = e.interface or ""
            if n ~= "loopback" and n ~= "lan" and not n:match("^lan%d") then
                l3dev = e.l3_device or e.device or ""
                if l3dev ~= "" then break end
            end
        end
    end

    local tx, rx = 0, 0
    if l3dev ~= "" then
        local base = "/sys/class/net/" .. l3dev .. "/statistics/"
        tx = tonumber(read_line(base .. "tx_bytes") or "0") or 0
        rx = tonumber(read_line(base .. "rx_bytes") or "0") or 0
    end

    http.prepare_content("application/json")
    http.write(jsonc.stringify({ tx_bytes = tx, rx_bytes = rx }))
end

-- =====================================================================
-- Local API: devices
-- =====================================================================

local function api_devices()
    local devices, seen = {}, {}

    local function guess_type(name)
        local n = (name or ""):lower()
        if n:match("iphone") or n:match("ipad") or n:match("android") or
            n:match("phone") or n:match("mobile") or n:match("pixel") or
            n:match("galaxy") or n:match("oneplus") or n:match("xiaomi") or
            n:match("huawei") or n:match("oppo") or n:match("vivo") then
            return "mobile"
        end
        return "laptop"
    end

    for line in (read_all("/tmp/dhcp.leases") or ""):gmatch("[^\n]+") do
        local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac then
            mac = mac:upper()
            if not seen[mac] then
                seen[mac] = true
                local h = (name and name ~= "*") and name or ""
                devices[#devices + 1] = {
                    mac    = mac,
                    ip     = ip or "",
                    name   = h,
                    type   = guess_type(h),
                    active = true,
                }
            end
        end
    end

    for line in (read_all("/proc/net/arp") or ""):gmatch("[^\n]+") do
        local ip, _, flags, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac and mac ~= "00:00:00:00:00:00" and ip ~= "IP" and flags == "0x2" then
            mac = mac:upper()
            if not seen[mac] then
                seen[mac] = true
                devices[#devices + 1] = {
                    mac    = mac,
                    ip     = ip or "",
                    name   = "",
                    type   = "laptop",
                    active = true,
                }
            end
        end
    end

    http.prepare_content("application/json")
    http.write(jsonc.stringify(devices))
end

-- =====================================================================
-- Local API: domains
-- =====================================================================

local function api_domains()
    local result = { top = {}, recent = {} }
    local source, lines = collect_domain_source()
    local counts = {}

    for i = 1, #lines do
        local d_val = lines[i]
        counts[d_val] = (counts[d_val] or 0) + 1
    end

    local sortable = {}
    for d_val, c in pairs(counts) do table.insert(sortable, {domain = d_val, count = c}) end
    table.sort(sortable, function(a, b) return a.count > b.count end)
    for i = 1, math.min(10, #sortable) do table.insert(result.top, sortable[i]) end

    local seen_recent = {}
    for i = #lines, 1, -1 do
        local d_val = lines[i]
        if not seen_recent[d_val] then
            seen_recent[d_val] = true
            table.insert(result.recent, {domain = d_val, count = counts[d_val]})
            if #result.recent >= 10 then break end
        end
    end

    if #result.top == 0 and #result.recent == 0 then source = "none" end

    http.prepare_content("application/json")
    http.write(jsonc.stringify({ source = source, top = result.top, recent = result.recent }))
end

-- =====================================================================
-- Page + Local-API Dispatcher
-- =====================================================================

local LOCAL_API = {
    sysinfo = api_sysinfo,
    netinfo = api_netinfo,
    traffic = api_traffic,
    devices = api_devices,
    domains = api_domains,
    oaf     = function()
        local path = http.getenv("PATH_INFO") or ""
        local sub  = path:match("/dashboard/api/oaf/([^/?#]+)")
        local ok, oaf = pcall(require, "luci.controller.api.oaf")
        if ok and oaf then
            if sub == "status" and type(oaf.action_status) == "function" then
                return oaf.action_status()
            elseif sub == "upload" and type(oaf.action_upload) == "function" then
                return oaf.action_upload()
            end
        end
        http.prepare_content("application/json")
        http.write('{"error":"OAF endpoint not found","success":false}')
    end,
}

M.dashboard_dispatch = function()
    local uri      = http.getenv("REQUEST_URI") or ""
    local endpoint = uri:match("/dashboard/api/([^/?#]+)")

    if endpoint then
        local sid, _ = check_session()
        if not sid then
            http.status(403, "Forbidden")
            http.prepare_content("application/json")
            http.write('{"error":"Forbidden","code":-1001}')
            return
        end

        local h = LOCAL_API[endpoint]
        if h then
            local ok, err = pcall(h)
            if not ok then
                http.prepare_content("application/json")
                http.write(jsonc.stringify({ error = tostring(err), code = 500 }))
            end
        else
            http.prepare_content("application/json")
            http.write('{"error":"Not found","code":404}')
        end
    else
        require("luci.template").render("dashboard/main", {
            prefix = d.build_url("admin", "dashboard")
        })
    end
end

return M
