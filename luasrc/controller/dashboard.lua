-- Dashboard Controller
-- entry({"admin","dashboard"}) → dashboard_dispatch()
--   → renders main.htm  OR  serves 5 local JSON APIs consumed by main.htm
-- entry({"dashboard-api"})     → dashboard_api()
--   → Vue-bundle API gateway (api_network / api_system / api_guide / api_nas)

local http       = require "luci.http"
local util       = require "luci.util"
local jsonc      = require "luci.jsonc"
local d          = require "luci.dispatcher"
local _          = require "luci.i18n".translate

-- 定义模块表 (兼容 Lua 5.1/5.4)
local M = {}

function M.index()
    d.entry({ "admin", "dashboard" }, d.call("dashboard_dispatch"), _("Dashboard"), 0).leaf = true
    d.entry({ "dashboard-api" }, d.call("dashboard_api")).leaf = true
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

    local release  = read_all("/etc/openwrt_release") or ""
    local firmware = release:match("DISTRIB_DESCRIPTION='([^']*)'")
        or release:match('DISTRIB_DESCRIPTION="([^"]*)"')
        or "OpenWrt"

    local kernel   = exec_trim("uname -r")
    if kernel == "" then kernel = "unknown" end

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

    local ustr       = read_line("/proc/uptime") or "0"
    local uptime_raw = math.floor(tonumber(ustr:match("^(%S+)")) or 0)

    local lavg       = read_line("/proc/loadavg") or "0"
    local load1      = tonumber(lavg:match("^(%S+)")) or 0
    local cpus       = 0
    for _ in (read_all("/proc/cpuinfo") or ""):gmatch("processor%s*:") do
        cpus = cpus + 1
    end
    if cpus == 0 then cpus = 1 end
    local cpuUsage = math.min(100, math.floor(load1 * 100 / cpus))

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
        model       = model,
        firmware    = firmware,
        kernel      = kernel,
        temp        = temp,
        systime_raw = os.time(),
        uptime_raw  = uptime_raw,
        cpuUsage    = cpuUsage,
        memUsage    = memUsage,
        hasSamba4   = hasSamba4
    }))
end

-- =====================================================================
-- Local API: netinfo
-- =====================================================================

local function api_netinfo()
    local uci = require("luci.model.uci").cursor()
    local wan = util.ubus("network.interface.wan", "status") or {}

    if not wan.up and not (wan["ipv4-address"] and #wan["ipv4-address"] > 0) then
        local dump = util.ubus("network.interface", "dump", {}) or {}
        for _, e in ipairs(dump.interface or dump.interfaces or {}) do
            local n = e.interface or ""
            if n ~= "loopback" and n ~= "lan" and not n:match("^lan%d") then
                if e["ipv4-address"] and #e["ipv4-address"] > 0 then
                    wan = e
                    break
                end
            end
        end
    end

    local wan_ip = ""
    if wan["ipv4-address"] and wan["ipv4-address"][1] then
        wan_ip = wan["ipv4-address"][1].address or ""
    end

    http.prepare_content("application/json")
    http.write(jsonc.stringify({
        wanStatus          = (wan.up == true or wan_ip ~= "") and "up" or "down",
        wanIp              = wan_ip,
        lanIp              = uci:get("network", "lan", "ipaddr") or "192.168.1.1",
        dns                = wan["dns-server"] or {},
        network_uptime_raw = wan.uptime or 0,
        connCount          = read_conntrack_count(),
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
}

M.dashboard_dispatch = function()
    local uri      = http.getenv("REQUEST_URI") or ""
    local endpoint = uri:match("/dashboard/api/([^/?#]+)")

    if endpoint then
        local sid, _ = check_session()
        if not sid then
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

-- =====================================================================
-- Vue-bundle Code Table
-- =====================================================================

local ROUTES = {
    ["GET:/u/network/status/"]              = { "api_network", "status" },
    ["GET:/u/network/statistics/"]          = { "api_network", "statistics" },
    ["GET:/network/device/list/"]           = { "api_network", "device_list" },
    ["GET:/network/port/list/"]             = { "api_network", "port_list" },
    ["GET:/network/interface/config/"]      = { "api_network", "interface_config_get" },
    ["POST:/network/interface/config/"]     = { "api_network", "interface_config_post" },
    ["POST:/network/checkPublicNet/"]       = { "api_network", "check_public_net" },
    ["GET:/system/status/"]                 = { "api_system", "status" },
    ["GET:/u/system/version/"]              = { "api_system", "version" },
    ["POST:/system/reboot/"]                = { "api_system", "reboot" },
    ["GET:/guide/dns-config/"]              = { "api_guide", "dns_config_get" },
    ["POST:/guide/dns-config/"]             = { "api_guide", "dns_config_post" },
    ["GET:/u/guide/ddns/"]                  = { "api_guide", "ddns_get" },
    ["POST:/u/guide/ddns/"]                 = { "api_guide", "ddns_post" },
    ["GET:/guide/docker/status/"]           = { "api_guide", "docker_status" },
    ["GET:/guide/docker/partition/list/"]   = { "api_guide", "docker_partition_list" },
    ["POST:/guide/docker/transfer/"]        = { "api_guide", "docker_transfer" },
    ["POST:/guide/docker/switch/"]          = { "api_guide", "docker_switch" },
    ["GET:/guide/download-service/status/"] = { "api_guide", "download_service_status" },
    ["GET:/nas/disk/status/"]               = { "api_nas", "disk_status" },
    ["GET:/u/nas/service/status/"]          = { "api_nas", "service_status" },
    ["POST:/nas/linkease/enable/"]          = { "api_nas", "linkease_enable" },
}

M.dashboard_api = function()
    local sid, _ = check_session()
    if not sid then
        http.prepare_content("application/json")
        http.write('{"success":-1001,"error":"Forbidden"}')
        return
    end

    local request_uri = http.getenv("REQUEST_URI") or ""
    local method      = http.getenv("REQUEST_METHOD") or "GET"

    local api_path    = request_uri:match("/dashboard%-api(/.*)") or "/"
    api_path          = api_path:gsub("%?.*$", "")
    if not api_path:match("/$") then api_path = api_path .. "/" end

    local route = ROUTES[method .. ":" .. api_path]
    if route then
        local ok, mod = pcall(require, "luci.dashboard." .. route[1])
        if ok and mod and type(mod[route[2]]) == "function" then
            local ok2, err = pcall(mod[route[2]])
            if not ok2 then
                http.prepare_content("application/json")
                http.write(jsonc.stringify({
                    success = 500,
                    error   = tostring(err),
                }))
            end
        else
            http.prepare_content("application/json")
            http.write(jsonc.stringify({
                success = 500,
                error   = "Module load failed: " .. tostring(mod),
            }))
        end
    else
        http.prepare_content("application/json")
        http.write('{"success":200,"result":{}}')
    end
end

return M
