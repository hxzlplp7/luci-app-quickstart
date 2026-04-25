-- Dashboard Controller
-- entry({"admin","dashboard"}) -> dashboard_dispatch()
--   -> renders main.htm OR serves 5 local JSON APIs consumed by main.htm
-- entry({"dashboard-api"}) -> dashboard_api()
--   -> Vue-bundle API gateway (api_network / api_system / api_guide / api_nas)

local http       = require "luci.http"
local util       = require "luci.util"
local jsonc      = require "luci.jsonc"
local d          = require "luci.dispatcher"
local fs         = require "nixio.fs"
local _          = require "luci.i18n".translate

-- Module table (Lua 5.1/5.4 compatible)
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
    local s = tostring(value or "")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

local function exec_trim(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    out = out:gsub("%s+$", "")
    return out
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

local function command_exists(cmd)
    local name = trim(cmd or "")
    if name == "" or not name:match("^[%w%._%-]+$") then
        return false
    end
    local ok = os.execute("command -v " .. name .. " >/dev/null 2>&1")
    return ok == 0 or ok == true
end

local DOMAIN_CACHE_FILE = "/tmp/.dashboard_domain_cache.json"
local DOMAIN_CACHE_TTL = 180
local TRAFFIC_STATE_FILE = "/tmp/.dashboard_traffic_state.json"
local DASHBOARD_CORE_URL = "http://127.0.0.1:19090"

local function fetch_dashboard_core_databus()
    local raw = exec_trim("wget -q -T 3 -O - " .. shell_quote(DASHBOARD_CORE_URL .. "/databus"))
    if raw == "" then
        return nil
    end

    local decoded = jsonc.parse(raw)
    if type(decoded) ~= "table" then
        return nil
    end

    if decoded.code == nil then
        decoded.code = 0
    end
    if decoded.timestamp == nil then
        decoded.timestamp = os.time()
    end

    return decoded
end

local function dashboard_core_error()
    return {
        code = 503,
        error = "dashboard-core unavailable",
    }
end

local function write_json(payload, status_code, status_text)
    if status_code and type(http.status) == "function" then
        http.status(status_code, status_text or "")
    end
    http.prepare_content("application/json")
    http.write(jsonc.stringify(payload or {}))
end

local function save_domain_cache(source, domains, realtime_rows, realtime_source)
    if trim(source or "") == "" or type(domains) ~= "table" or #domains == 0 then
        return
    end

    local cached_domains = {}
    local max_domains = math.min(#domains, 4000)
    for i = 1, max_domains do
        cached_domains[i] = domains[i]
    end

    local cached_realtime = {}
    if type(realtime_rows) == "table" then
        local max_rows = math.min(#realtime_rows, 40)
        for i = 1, max_rows do
            local row = realtime_rows[i]
            if type(row) == "table" then
                cached_realtime[#cached_realtime + 1] = {
                    domain = row.domain,
                    count = tonumber(row.count) or 0,
                }
            end
        end
    end

    local payload = {
        timestamp = os.time(),
        source = trim(source or "none"),
        realtime_source = trim(realtime_source or "none"),
        domains = cached_domains,
        realtime = cached_realtime,
    }

    local encoded = jsonc.stringify(payload)
    if encoded and encoded ~= "" then
        fs.writefile(DOMAIN_CACHE_FILE, encoded)
    end
end

local function load_domain_cache()
    local raw = fs.readfile(DOMAIN_CACHE_FILE)
    if not raw or raw == "" then
        return nil
    end

    local decoded = jsonc.parse(raw)
    if type(decoded) ~= "table" then
        return nil
    end

    local ts = tonumber(decoded.timestamp) or 0
    if ts <= 0 or (os.time() - ts) > DOMAIN_CACHE_TTL then
        return nil
    end

    if type(decoded.domains) ~= "table" or #decoded.domains == 0 then
        return nil
    end

    return {
        source = trim(decoded.source or "cache"),
        realtime_source = trim(decoded.realtime_source or "cache"),
        domains = decoded.domains,
        realtime = type(decoded.realtime) == "table" and decoded.realtime or {},
    }
end

local function load_json_file(path)
    local raw = fs.readfile(path)
    if not raw or raw == "" then
        return {}
    end

    local decoded = jsonc.parse(raw)
    return type(decoded) == "table" and decoded or {}
end

local function save_json_file(path, payload)
    local encoded = jsonc.stringify(payload or {})
    if encoded and encoded ~= "" then
        fs.writefile(path, encoded)
    end
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

local function first_ipv6_address(status)
    if type(status) ~= "table" then
        return ""
    end

    local list = status["ipv6-address"] or {}
    if type(list) == "table" and type(list[1]) == "table" then
        return trim(list[1].address or "")
    end

    return trim(status.ip6addr or "")
end

local function read_ipv6_from_device(dev)
    dev = trim(dev)
    if dev == "" then return "" end
    local s = exec_trim("ip -6 addr show dev " .. shell_quote(dev) .. " scope global | awk '/inet6 / {print $2; exit}' | cut -d/ -f1")
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

local function read_any_global_ipv4()
    return exec_trim("ip -4 addr show scope global up | awk '/inet / && $NF != \"lo\" {print $2; exit}' | cut -d/ -f1")
end

local function read_any_global_ipv6()
    return exec_trim("ip -6 addr show scope global up | awk '/inet6 / {print $2; exit}' | cut -d/ -f1")
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
    if wan_ip == "" then
        wan_ip = read_any_global_ipv4()
    end

    local wan_ipv6 = first_ipv6_address(best)
    if wan_ipv6 == "" then
        wan_ipv6 = read_ipv6_from_device(best.l3_device or best.device or default_dev)
    end
    if wan_ipv6 == "" then
        wan_ipv6 = read_any_global_ipv6()
    end

    -- FakeIP/transparent-proxy setups often expose non-standard interface states.
    -- Prefer route/IP evidence first; keep active probing diagnostic-only.
    local link_up = best.up == true
    local has_wan_ip = wan_ip ~= "" or wan_ipv6 ~= ""
    local gateway = read_default_route_gateway()
    local route_ready = has_default_route(best) or default_dev ~= "" or gateway ~= ""

    local probe_ok = false
    if link_up then
        probe_ok = proactive_ping_check()
    end

    local is_online = false
    local online_reason = "no-route-no-ip"
    if route_ready and has_wan_ip then
        is_online = true
        online_reason = "route+ip"
    elseif route_ready and default_dev ~= "" then
        is_online = true
        online_reason = "default-route"
    elseif has_wan_ip and (link_up or default_dev ~= "") then
        is_online = true
        online_reason = "ip-present"
    elseif probe_ok then
        is_online = true
        online_reason = "probe-ok"
    end

    return {
        name = best_name,
        status = best,
        wan_ip = wan_ip,
        wan_ipv6 = wan_ipv6,
        online = is_online,
        link_up = link_up,
        route_ready = route_ready,
        probe_ok = probe_ok,
        gateway = gateway,
        online_reason = online_reason,
        dns = to_array(best and best["dns-server"] or {}),
        uptime = tonumber(best and best.uptime or 0) or 0,
    }
end

local function build_oaf_status_data()
    local ok, oaf = pcall(require, "luci.controller.api.oaf")
    if ok and oaf and type(oaf.get_status_data) == "function" then
        local ok_status, data = pcall(oaf.get_status_data)
        if ok_status and type(data) == "table" then
            return data
        end
    end

    return {
        success = false,
        available = false,
        engine = "",
        current_version = "",
        active_apps = {},
        class_stats = {},
    }
end

local function build_dashboard_databus()
    local sysinfo = build_sysinfo_data()
    local netinfo = build_netinfo_data()
    local traffic = build_traffic_data()
    local devices = build_devices_data()
    local domain_activity = { source = "none", realtime_source = "none", top = {}, recent = {}, realtime = {} }
    local oaf_status = build_oaf_status_data()

    local realtime_urls = {}

    local online_apps = {}
    local class_stats = {}
    local recognition_source = "domain-heuristic"
    local recognition_engine = "domain-heuristic"
    local feature_version = ""

    if type(oaf_status.active_apps) == "table" and #oaf_status.active_apps > 0 then
        for _, app in ipairs(oaf_status.active_apps) do
            online_apps[#online_apps + 1] = {
                id = tonumber(app.id) or 0,
                name = trim(app.name or ""),
                class = trim(app.class or ""),
                class_label = trim(app.class_label or app.class or ""),
                devices = tonumber(app.devices or 0) or 0,
                last_seen = tonumber(app.last_seen or 0) or 0,
                icon = trim(app.icon or ""),
                time = tonumber(app.time or 0) or 0,
                source = "oaf",
            }
        end
        class_stats = type(oaf_status.class_stats) == "table" and oaf_status.class_stats or {}
        recognition_source = "oaf"
        recognition_engine = trim(oaf_status.engine or "") ~= "" and trim(oaf_status.engine) or "OpenAppFilter"
        feature_version = trim(oaf_status.current_version or "")
    else
        online_apps = {}
    end

    return {
        code = 0,
        timestamp = os.time(),
        status = {
            online = netinfo.wanStatus == "up",
            internet = netinfo.wanStatus,
            online_reason = netinfo.onlineReason,
            link_up = netinfo.linkUp and true or false,
            route_ready = netinfo.routeReady and true or false,
            probe_ok = netinfo.probeOk and true or false,
            conn_count = netinfo.connCount or 0,
        },
        system_status = sysinfo,
        network_status = {
            internet = netinfo.wanStatus == "up" and 0 or 1,
            online_reason = netinfo.onlineReason,
            interface = netinfo.interfaceName,
            lan = {
                ip = netinfo.lanIp,
                dns = netinfo.dns,
            },
            wan = {
                ip = netinfo.wanIp,
                ipv6 = netinfo.wanIpv6,
                gateway = netinfo.gateway,
                dns = netinfo.dns,
            },
        },
        interface_traffic = {
            interface = traffic.interface or "",
            tx_bytes = traffic.tx_bytes or 0,
            rx_bytes = traffic.rx_bytes or 0,
            tx_rate = traffic.tx_rate or 0,
            rx_rate = traffic.rx_rate or 0,
            sampled_at = traffic.sampled_at or 0,
            source = traffic.source or "userspace-sysfs",
        },
        realtime_urls = {
            source = domain_activity.source,
            total = #realtime_urls,
            list = realtime_urls,
        },
        online_apps = {
            total = #online_apps,
            list = online_apps,
        },
        app_recognition = {
            available = (recognition_source == "oaf") or (#online_apps > 0),
            source = recognition_source,
            engine = recognition_engine,
            feature_version = feature_version,
            class_stats = class_stats,
        },
        devices = {
            total = #devices,
            list = devices,
        },
    }
end

local function api_databus()
    local data = fetch_dashboard_core_databus()
    if not data then
        data = build_dashboard_databus()
        return write_json(data)
    end

    local oaf_status = build_oaf_status_data()

    if type(oaf_status.active_apps) == "table" and #oaf_status.active_apps > 0 then
        local online_apps = {}
        for _, app in ipairs(oaf_status.active_apps) do
            online_apps[#online_apps + 1] = {
                id = tonumber(app.id) or 0,
                name = trim(app.name or ""),
                class = trim(app.class or ""),
                class_label = trim(app.class_label or app.class or ""),
                devices = tonumber(app.devices or 0) or 0,
                last_seen = tonumber(app.last_seen or 0) or 0,
                icon = trim(app.icon or ""),
                time = tonumber(app.time or 0) or 0,
                source = "oaf",
            }
        end
        data.online_apps = {
            total = #online_apps,
            list = online_apps,
        }
        data.app_recognition = {
            available = true,
            source = "oaf",
            engine = trim(oaf_status.engine or "") ~= "" and trim(oaf_status.engine) or "OpenAppFilter",
            feature_version = trim(oaf_status.current_version or ""),
            class_stats = type(oaf_status.class_stats) == "table" and oaf_status.class_stats or {},
        }
    end

    write_json(data)
end

-- =====================================================================
-- Page + Local-API Dispatcher
-- =====================================================================

local function get_backend_databus_or_error()
    local data = fetch_dashboard_core_databus()
    if not data then
        return nil, dashboard_core_error()
    end
    return data, nil
end

local function build_compat_netinfo(databus)
    local status = type(databus.status) == "table" and databus.status or {}
    local network = type(databus.network_status) == "table" and databus.network_status or {}
    local lan = type(network.lan) == "table" and network.lan or {}
    local wan = type(network.wan) == "table" and network.wan or {}
    local internet = trim(status.internet or "")
    local online = status.online and true or false

    if internet == "" then
        internet = online and "up" or "down"
    end

    return {
        wanStatus = (internet == "up" or online) and "up" or "down",
        wanIp = wan.ip or "",
        wanIpv6 = wan.ipv6 or "",
        lanIp = lan.ip or "",
        dns = wan.dns or lan.dns or {},
        network_uptime_raw = tonumber(network.uptime_raw or network.network_uptime_raw or 0) or 0,
        connCount = tonumber(status.conn_count or status.connCount or 0) or 0,
        interfaceName = network.interface or "",
        gateway = wan.gateway or "",
        linkUp = status.link_up and true or false,
        routeReady = status.route_ready and true or false,
        probeOk = status.probe_ok and true or false,
        onlineReason = status.online_reason or network.online_reason or "",
    }
end

local function build_compat_payload(endpoint, databus)
    if endpoint == "sysinfo" then
        return type(databus.system_status) == "table" and databus.system_status or {}
    elseif endpoint == "netinfo" then
        return build_compat_netinfo(databus)
    elseif endpoint == "traffic" then
        return type(databus.interface_traffic) == "table" and databus.interface_traffic or {}
    elseif endpoint == "devices" then
        local devices = databus.devices
        if type(devices) == "table" and type(devices.list) == "table" then
            return devices.list
        end
        return type(devices) == "table" and devices or {}
    elseif endpoint == "domains" then
        local domains = type(databus.domains) == "table" and databus.domains or {}
        if domains.realtime == nil and type(databus.realtime_urls) == "table" then
            local realtime = {}
            for _, item in ipairs(databus.realtime_urls.list or {}) do
                realtime[#realtime + 1] = {
                    domain = item.domain,
                    count = tonumber(item.count or item.hits or 0) or 0,
                }
            end
            domains.realtime = realtime
            domains.realtime_source = databus.realtime_urls.source or domains.realtime_source or "dashboard-core"
        end
        return domains
    end

    return databus
end

local function api_backend_compat(endpoint)
    local data, err = get_backend_databus_or_error()
    if not data then
        return write_json(err, 503, "Service Unavailable")
    end
    write_json(build_compat_payload(endpoint, data))
end

local LOCAL_API = {
    sysinfo = function() return api_backend_compat("sysinfo") end,
    netinfo = function() return api_backend_compat("netinfo") end,
    traffic = function() return api_backend_compat("traffic") end,
    devices = function() return api_backend_compat("devices") end,
    domains = function() return api_backend_compat("domains") end,
    databus = api_databus,
    backend = api_databus,
    common = api_databus,
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
