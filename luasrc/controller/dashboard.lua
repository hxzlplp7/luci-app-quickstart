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

local function collect_dnsmasq_activity(command)
    local domains = {}
    local ip_map = {}
    local pipe = io.popen(command .. " 2>/dev/null")
    if not pipe then
        return domains, ip_map
    end

    local function record_ip_domain(ip, domain)
        if trim(ip) == "" or not domain then
            return
        end
        local bucket = ip_map[ip]
        if not bucket then
            bucket = {}
            ip_map[ip] = bucket
        end
        bucket[domain] = (bucket[domain] or 0) + 1
    end

    for line in pipe:lines() do
        local raw = tostring(line or "")

        local extracted = extract_domains_from_line(raw)
        for _, domain in ipairs(extracted) do
            domains[#domains + 1] = domain
        end

        local reply_domain, reply_ip = raw:match("reply%s+([%w%-%.]+)%s+is%s+([%d%.]+)")
        if not reply_domain then
            reply_domain, reply_ip = raw:match("cached%s+([%w%-%.]+)%s+is%s+([%d%.]+)")
        end
        local normalized = normalize_domain(reply_domain)
        if normalized and reply_ip then
            record_ip_domain(reply_ip, normalized)
        end
    end

    pipe:close()
    return domains, ip_map
end

local function collect_domains_from_conntrack(ip_map)
    local domains = {}
    if type(ip_map) ~= "table" or next(ip_map) == nil then
        return domains
    end

    local pipe = io.popen("conntrack -L 2>/dev/null")
    if not pipe then
        return domains
    end

    for line in pipe:lines() do
        local dst_ip = tostring(line or ""):match("dst=([%d%.]+)")
        if dst_ip and ip_map[dst_ip] then
            for domain, weight in pairs(ip_map[dst_ip]) do
                local times = math.floor(tonumber(weight) or 1)
                if times < 1 then
                    times = 1
                elseif times > 20 then
                    times = 20
                end
                for _ = 1, times do
                    domains[#domains + 1] = domain
                    if #domains >= 8000 then
                        pipe:close()
                        return domains
                    end
                end
            end
        end
    end

    pipe:close()
    return domains
end

local function collect_conntrack_domain_rows(ip_map, limit)
    local rows = {}
    if type(ip_map) ~= "table" or next(ip_map) == nil then
        return rows
    end

    local pipe = io.popen("conntrack -L 2>/dev/null")
    if not pipe then
        return rows
    end

    local counts = {}
    local last_seen = {}
    local seq = 0

    for line in pipe:lines() do
        local dst_ip = tostring(line or ""):match("dst=([%d%.]+)")
        local bucket = dst_ip and ip_map[dst_ip] or nil
        if bucket then
            local best_domain = nil
            local best_weight = -1
            for domain, weight in pairs(bucket) do
                local w = tonumber(weight) or 0
                if w > best_weight then
                    best_weight = w
                    best_domain = domain
                end
            end

            if best_domain then
                counts[best_domain] = (counts[best_domain] or 0) + 1
                seq = seq + 1
                last_seen[best_domain] = seq
            end
        end
    end

    pipe:close()

    for domain, count in pairs(counts) do
        rows[#rows + 1] = {
            domain = domain,
            count = count,
            _last_seen = last_seen[domain] or 0,
        }
    end

    table.sort(rows, function(a, b)
        if (a.count or 0) == (b.count or 0) then
            return (a._last_seen or 0) > (b._last_seen or 0)
        end
        return (a.count or 0) > (b.count or 0)
    end)

    local max_rows = math.max(1, tonumber(limit) or 20)
    while #rows > max_rows do
        table.remove(rows)
    end
    for _, row in ipairs(rows) do
        row._last_seen = nil
    end

    return rows
end

local function collect_domains_from_appfilter_visitlist()
    local domains = {}
    local ok, payload = pcall(util.ubus, "appfilter", "visit_list", {})
    if not ok or type(payload) ~= "table" then
        return domains
    end

    local function push_domain(value, weight)
        local domain = normalize_domain(value)
        if domain then
            local times = math.floor(tonumber(weight) or 1)
            if times < 1 then
                times = 1
            elseif times > 200 then
                times = 200
            end
            for _ = 1, times do
                domains[#domains + 1] = domain
                if #domains >= 8000 then
                    return
                end
            end
        end
    end

    local function pick_weight(node)
        if type(node) ~= "table" then
            return 1
        end
        local candidates = {
            node.count, node.cnt, node.hits, node.hit, node.times, node.visits,
            node.visit_count, node.requests, node.req, node.reqs, node.freq, node.frequency,
        }
        for _, raw in ipairs(candidates) do
            local parsed = tonumber(raw)
            if parsed and parsed > 0 then
                return parsed
            end
        end
        return 1
    end

    local function walk(node)
        if #domains >= 8000 then
            return
        end
        local t = type(node)
        if t == "table" then
            local weight = pick_weight(node)
            local local_seen = {}
            for k, v in pairs(node) do
                local key = tostring(k):lower()
                if type(v) == "string" then
                    if key:find("domain", 1, true) or key:find("host", 1, true) or key:find("sni", 1, true) or key:find("url", 1, true) then
                        local candidate = tostring(v)
                        if key:find("url", 1, true) then
                            candidate = candidate:match("^https?://([^/%?#:]+)") or candidate
                        end
                        local normalized = normalize_domain(candidate)
                        if normalized and not local_seen[normalized] then
                            local_seen[normalized] = true
                            push_domain(normalized, weight)
                            if #domains >= 8000 then
                                return
                            end
                        end
                    end
                elseif type(v) == "table" then
                    walk(v)
                    if #domains >= 8000 then
                        return
                    end
                end
            end
        elseif t == "string" then
            local extracted = extract_domains_from_line(node)
            for _, dval in ipairs(extracted) do
                push_domain(dval, 1)
                if #domains >= 8000 then
                    return
                end
            end
        end
    end

    walk(payload)
    return domains
end

local function collect_domain_source()
    local dns_file_sources = {
        { name = "smartdns", path = "/tmp/smartdns.log", command = "tail -n 6000 /tmp/smartdns.log" },
        { name = "adguardhome", path = "/tmp/AdGuardHome.log", command = "tail -n 6000 /tmp/AdGuardHome.log" },
        { name = "mosdns", path = "/tmp/mosdns.log", command = "tail -n 6000 /tmp/mosdns.log" },
    }

    local plugin_sources = {
        { name = "openclash", path = "/tmp/openclash.log", command = "tail -n 6000 /tmp/openclash.log" },
        { name = "passwall", path = "/tmp/log/passwall.log", command = "tail -n 6000 /tmp/log/passwall.log" },
        { name = "passwall2", path = "/tmp/log/passwall2.log", command = "tail -n 6000 /tmp/log/passwall2.log" },
        { name = "homeproxy", path = "/tmp/homeproxy.log", command = "tail -n 6000 /tmp/homeproxy.log" },
        { name = "mihomo", path = "/tmp/mihomo.log", command = "tail -n 6000 /tmp/mihomo.log" },
        { name = "sing-box", path = "/tmp/sing-box.log", command = "tail -n 6000 /tmp/sing-box.log" },
    }

    local merged = {}
    local source_flags = {}
    local max_merged = 16000
    local realtime_rows = {}
    local realtime_source = "none"

    local function append_domains(source_name, domains, cap)
        if type(domains) ~= "table" or #domains == 0 or #merged >= max_merged then
            return
        end
        source_flags[#source_flags + 1] = source_name
        local max_take = tonumber(cap) or #domains
        if max_take < 1 then
            return
        end
        local taken = 0
        for _, dval in ipairs(domains) do
            merged[#merged + 1] = dval
            taken = taken + 1
            if #merged >= max_merged then
                break
            end
            if taken >= max_take then
                break
            end
        end
    end

    append_domains("appfilter", collect_domains_from_appfilter_visitlist(), 4000)

    if #merged < max_merged then
        local dnsmasq_domains, dnsmasq_ip_map = collect_dnsmasq_activity(
            "logread | grep -iE 'dnsmasq' | tail -n 12000"
        )
        if #dnsmasq_domains > 0 then
            append_domains("dnsmasq-logread", dnsmasq_domains, 7000)
        end
        if #merged < max_merged then
            local conntrack_domains = collect_domains_from_conntrack(dnsmasq_ip_map)
            if #conntrack_domains > 0 then
                append_domains("conntrack+dnsmasq", conntrack_domains, 5000)
            end
        end
        realtime_rows = collect_conntrack_domain_rows(dnsmasq_ip_map, 25)
        if #realtime_rows > 0 then
            realtime_source = "conntrack+dnsmasq"
        end
    end

    for _, source in ipairs(dns_file_sources) do
        if #merged >= max_merged then
            break
        end
        if path_exists(source.path) then
            local domains = collect_domains_from_command(source.command)
            if #domains > 0 then
                append_domains(source.name, domains, 3000)
            end
        end
    end

    if #merged < max_merged then
        local dns_logread = collect_domains_from_command(
            "logread | grep -iE 'dnsmasq|smartdns|adguardhome|mosdns|unbound|pdnsd|chinadns' | tail -n 8000"
        )
        if #dns_logread > 0 then
            append_domains("logread-dns", dns_logread, 4000)
        end
    end

    if #merged == 0 then
        for _, source in ipairs(plugin_sources) do
            if #merged >= max_merged then
                break
            end
            if path_exists(source.path) then
                local domains = collect_domains_from_command(source.command)
                if #domains > 0 then
                    append_domains(source.name, domains, 2000)
                end
            end
        end
    end

    if #merged == 0 then
        local proxy_logread = collect_domains_from_command(
            "logread | grep -iE 'openclash|passwall|mihomo|sing-box|homeproxy|appfilter' | tail -n 6000"
        )
        if #proxy_logread > 0 then
            append_domains("logread-proxy", proxy_logread, 6000)
        end
    end

    if #merged > 0 then
        local merged_source = (#source_flags > 0) and table.concat(source_flags, "+") or "proxy-log"
        save_domain_cache(merged_source, merged, realtime_rows, realtime_source)
        return merged_source, merged, realtime_rows, realtime_source
    end

    local cache = load_domain_cache()
    if cache then
        local cache_source = trim(cache.source)
        if cache_source == "" then
            cache_source = "cache"
        else
            cache_source = "cache+" .. cache_source
        end
        return cache_source, cache.domains, cache.realtime, cache.realtime_source
    end

    return "none", {}, realtime_rows, realtime_source
end

-- =====================================================================
-- Local API: sysinfo
-- =====================================================================

local function build_sysinfo_data()
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

    -- CPU usage uses cross-request delta sampling with polling interval as the sample window.
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

    local meminfo  = read_all("/proc/meminfo") or ""
    local mem      = {}
    for k, v in meminfo:gmatch("(%S+):%s+(%d+)") do
        mem[k] = tonumber(v)
    end
    local mt       = mem.MemTotal or 1
    local ma       = mem.MemAvailable or mem.MemFree or 0
    local memUsage = math.floor((mt - ma) * 100 / mt)

    local hasSamba4 = path_exists("/usr/lib/lua/luci/controller/samba4.lua") or path_exists("/etc/config/samba4")

    return {
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
    }
end

local function api_sysinfo()
    http.prepare_content("application/json")
    http.write(jsonc.stringify(build_sysinfo_data()))
end

-- =====================================================================
-- Local API: netinfo
-- =====================================================================

local function build_netinfo_data()
    local uci = require("luci.model.uci").cursor()
    local ok_uplink, uplink = pcall(resolve_uplink_status)
    if not ok_uplink or type(uplink) ~= "table" then
        local default_dev = read_default_route_device()
        local fallback_wan = read_ipv4_from_device(default_dev)
        local fallback_wan6 = read_ipv6_from_device(default_dev)
        if fallback_wan == "" then
            fallback_wan = exec_trim("ip -4 addr show scope global | awk '/inet / && $NF != \"lo\" {print $2; exit}' | cut -d/ -f1")
        end

        uplink = {
            name = default_dev ~= "" and default_dev or "wan",
            wan_ip = fallback_wan,
            wan_ipv6 = fallback_wan6,
            online = default_dev ~= "" or fallback_wan ~= "" or fallback_wan6 ~= "",
            dns = {},
            uptime = 0,
            gateway = read_default_route_gateway(),
            link_up = false,
            route_ready = default_dev ~= "",
            probe_ok = false,
            online_reason = default_dev ~= "" and "default-route" or "fallback",
        }
    end

    local ok_lan, lan_ip = pcall(resolve_lan_ip, uci)
    if not ok_lan or trim(lan_ip or "") == "" then
        lan_ip = trim(uci:get("network", "lan", "ipaddr") or "")
        if lan_ip == "" then
            lan_ip = read_ipv4_from_device("br-lan")
        end
    end

    return {
        wanStatus          = uplink.online and "up" or "down",
        wanIp              = uplink.wan_ip,
        wanIpv6            = uplink.wan_ipv6,
        lanIp              = lan_ip,
        dns                = uplink.dns,
        network_uptime_raw = uplink.uptime,
        connCount          = read_conntrack_count(),
        interfaceName      = uplink.name,
        gateway            = uplink.gateway,
        linkUp             = uplink.link_up,
        routeReady         = uplink.route_ready,
        probeOk            = uplink.probe_ok,
        onlineReason       = uplink.online_reason,
    }
end

local function api_netinfo()
    http.prepare_content("application/json")
    http.write(jsonc.stringify(build_netinfo_data()))
end

-- =====================================================================
-- Local API: traffic
-- =====================================================================

local function build_traffic_data()
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

    return { tx_bytes = tx, rx_bytes = rx, interface = l3dev }
end

local function api_traffic()
    local data = build_traffic_data()
    http.prepare_content("application/json")
    http.write(jsonc.stringify({ tx_bytes = data.tx_bytes, rx_bytes = data.rx_bytes }))
end

-- =====================================================================
-- Local API: devices
-- =====================================================================

local function build_devices_data()
    local devices, seen = {}, {}

    local function guess_type(text)
        local n = (text or ""):lower()
        if n:match("iphone") or n:match("ipad") or n:match("android") or
            n:match("phone") or n:match("mobile") or n:match("pixel") or
            n:match("galaxy") or n:match("oneplus") or n:match("xiaomi") or
            n:match("huawei") or n:match("oppo") or n:match("vivo") or
            n:match("redmi") or n:match("honor") then
            return "mobile"
        end
        return "laptop"
    end

    local function normalize_mac(mac)
        local m = trim(mac or ""):upper()
        if m:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
            return m
        end
        return ""
    end

    local function resolve_lan_device_for_scan()
        local uci = require("luci.model.uci").cursor()
        local lan_if = trim(uci:get("network", "lan", "device") or uci:get("network", "lan", "ifname") or "")
        if lan_if ~= "" then
            return lan_if
        end
        local lan_status = util.ubus("network.interface.lan", "status", {}) or {}
        lan_if = trim(lan_status.l3_device or lan_status.device or "")
        if lan_if ~= "" then
            return lan_if
        end
        return "br-lan"
    end

    local function add_device(ip, mac, name, detail)
        local ip_val = trim(ip or "")
        if ip_val == "" then
            return
        end
        local mac_val = normalize_mac(mac)
        local uniq = (mac_val ~= "" and mac_val ~= "00:00:00:00:00:00") and ("mac:" .. mac_val) or ("ip:" .. ip_val)
        if seen[uniq] then
            return
        end

        local host = trim(name or "")
        if host == "-" or host == "*" then
            host = ""
        end

        seen[uniq] = true
        devices[#devices + 1] = {
            mac    = mac_val ~= "" and mac_val or ip_val,
            ip     = ip_val,
            name   = host,
            type   = guess_type(host ~= "" and host or trim(detail or "")),
            active = true,
        }
    end

    local lan_if = resolve_lan_device_for_scan()
    local lease_name, lease_mac = {}, {}
    for line in (read_all("/tmp/dhcp.leases") or ""):gmatch("[^\n]+") do
        local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if ip then
            if name and name ~= "*" then
                lease_name[ip] = name
            end
            local norm = normalize_mac(mac)
            if norm ~= "" then
                lease_mac[ip] = norm
            end
        end
    end

    local arp_mac = {}
    for line in (read_all("/proc/net/arp") or ""):gmatch("[^\n]+") do
        local ip, _, flags, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if ip and ip ~= "IP" and flags == "0x2" then
            local norm = normalize_mac(mac)
            if norm ~= "" then
                arp_mac[ip] = norm
            end
        end
    end

    if command_exists("arp-scan") then
        local scan_cmd
        if path_exists("/tmp/dhcp.leases") then
            scan_cmd = "arp-scan --interface=" .. shell_quote(lan_if) ..
                [[ --localnet 2>/dev/null | awk 'NR==FNR {name[$3]=$4; next} /^[0-9]+\./ { host=(name[$1] && name[$1]!="*") ? name[$1] : "-"; printf "%s\t%s\n", $1, host }' /tmp/dhcp.leases - 2>/dev/null]]
        else
            scan_cmd = "arp-scan --interface=" .. shell_quote(lan_if) ..
                [[ --localnet 2>/dev/null | awk '/^[0-9]+\./ { printf "%s\t-\n", $1 }' 2>/dev/null]]
        end
        local pipe = io.popen(scan_cmd)
        if pipe then
            for line in pipe:lines() do
                local ip, host = tostring(line or ""):match("^(%S+)%s+(.+)$")
                if ip then
                    local resolved_host = trim(host or "")
                    if resolved_host == "-" or resolved_host == "*" then
                        resolved_host = lease_name[ip] or ""
                    end
                    add_device(ip, arp_mac[ip] or lease_mac[ip] or "", resolved_host, "")
                end
            end
            pipe:close()
        end
    end

    if #devices == 0 then
        local neigh_cmd = "ip neigh show dev " .. shell_quote(lan_if) .. " 2>/dev/null"
        local pipe = io.popen(neigh_cmd)
        if pipe then
            for line in pipe:lines() do
                local raw = tostring(line or "")
                if not raw:find("FAILED", 1, true) and not raw:find("INCOMPLETE", 1, true) then
                    local ip, mac = raw:match("^(%d+%.%d+%.%d+%.%d+)%s+.-lladdr%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
                    if ip then
                        add_device(ip, mac, lease_name[ip] or "", raw)
                    end
                end
            end
            pipe:close()
        end
    end

    if #devices == 0 then
        for line in (read_all("/proc/net/arp") or ""):gmatch("[^\n]+") do
            local ip, _, flags, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if ip ~= "IP" and flags == "0x2" and mac then
                add_device(ip, mac, lease_name[ip] or "", "")
            end
        end
    end

    table.sort(devices, function(a, b)
        return (a.ip or "") < (b.ip or "")
    end)

    return devices
end

local function api_devices()
    http.prepare_content("application/json")
    http.write(jsonc.stringify(build_devices_data()))
end

-- =====================================================================
-- Local API: domains
-- =====================================================================

local function collect_domain_activity(limit_top, limit_recent)
    local result = { source = "none", realtime_source = "none", top = {}, recent = {}, realtime = {}, lines = {} }
    local source, lines, realtime_rows, realtime_source = collect_domain_source()
    local counts = {}
    result.source = source
    result.realtime_source = realtime_source or "none"
    result.lines = lines
    result.realtime = type(realtime_rows) == "table" and realtime_rows or {}

    for i = 1, #lines do
        local d_val = lines[i]
        counts[d_val] = (counts[d_val] or 0) + 1
    end

    local sortable = {}
    for d_val, c in pairs(counts) do table.insert(sortable, {domain = d_val, count = c}) end
    table.sort(sortable, function(a, b) return a.count > b.count end)
    for i = 1, math.min(limit_top or 10, #sortable) do table.insert(result.top, sortable[i]) end

    local seen_recent = {}
    for i = #lines, 1, -1 do
        local d_val = lines[i]
        if not seen_recent[d_val] then
            seen_recent[d_val] = true
            table.insert(result.recent, {domain = d_val, count = counts[d_val]})
            if #result.recent >= (limit_recent or 10) then break end
        end
    end

    if #result.top == 0 and #result.recent == 0 then result.source = "none" end
    return result
end

local function build_domains_data()
    local activity = collect_domain_activity(25, 25)
    return {
        source = activity.source,
        realtime_source = activity.realtime_source,
        top = activity.top,
        recent = activity.recent,
        realtime = activity.realtime,
    }
end

local function api_domains()
    http.prepare_content("application/json")
    http.write(jsonc.stringify(build_domains_data()))
end

local DOMAIN_APP_RULES = {
    { app = "YouTube", class = "video", patterns = { "youtube.com", "googlevideo.com", "ytimg.com" } },
    { app = "Netflix", class = "video", patterns = { "netflix.com", "nflxvideo.net" } },
    { app = "Bilibili", class = "video", patterns = { "bilibili.com", "bilivideo.com" } },
    { app = "TikTok", class = "social", patterns = { "tiktok.com", "byteoversea.com", "musical.ly" } },
    { app = "Douyin", class = "social", patterns = { "douyin.com", "douyincdn.com" } },
    { app = "WeChat", class = "social", patterns = { "wechat.com", "weixin.qq.com", "qpic.cn" } },
    { app = "QQ", class = "social", patterns = { "qq.com", "qzone.qq.com", "tencent.com" } },
    { app = "Telegram", class = "social", patterns = { "telegram.org", "t.me" } },
    { app = "Discord", class = "social", patterns = { "discord.com", "discord.gg" } },
    { app = "GitHub", class = "developer", patterns = { "github.com", "githubusercontent.com" } },
    { app = "Steam", class = "game", patterns = { "steampowered.com", "steamstatic.com" } },
    { app = "PlayStation", class = "game", patterns = { "playstation.com", "psn" } },
    { app = "Xbox", class = "game", patterns = { "xboxlive.com", "xbox.com" } },
    { app = "Apple", class = "cloud", patterns = { "apple.com", "icloud.com", "mzstatic.com" } },
    { app = "Google", class = "search", patterns = { "google.com", "gstatic.com", "googleapis.com" } },
    { app = "Microsoft", class = "cloud", patterns = { "microsoft.com", "live.com", "office.com" } },
}

local function classify_domain_app(domain)
    local dval = trim(domain):lower()
    if dval == "" then
        return nil, nil
    end

    for _, rule in ipairs(DOMAIN_APP_RULES) do
        for _, pat in ipairs(rule.patterns) do
            if dval:find(pat, 1, true) then
                return rule.app, rule.class
            end
        end
    end

    return nil, nil
end

local function build_heuristic_apps(domain_activity)
    local apps = {}
    local by_key = {}

    for idx, domain in ipairs(domain_activity.lines or {}) do
        local app_name, app_class = classify_domain_app(domain)
        if app_name then
            local key = app_name .. "::" .. (app_class or "")
            local entry = by_key[key]
            if not entry then
                entry = {
                    id = 0,
                    name = app_name,
                    class = app_class or "",
                    class_label = app_class or "",
                    hits = 0,
                    latest_idx = 0,
                    source = "domain-heuristic",
                }
                by_key[key] = entry
                apps[#apps + 1] = entry
            end
            entry.hits = entry.hits + 1
            entry.latest_idx = idx
        end
    end

    table.sort(apps, function(a, b)
        if (a.hits or 0) == (b.hits or 0) then
            return (a.latest_idx or 0) > (b.latest_idx or 0)
        end
        return (a.hits or 0) > (b.hits or 0)
    end)

    while #apps > 12 do
        table.remove(apps)
    end

    return apps
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
    local domain_activity = collect_domain_activity(20, 20)
    local oaf_status = build_oaf_status_data()

    local realtime_urls = {}
    for i, item in ipairs(domain_activity.recent or {}) do
        realtime_urls[#realtime_urls + 1] = {
            rank = i,
            domain = item.domain,
            hits = item.count or 0,
            source = domain_activity.source,
        }
    end

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
        online_apps = build_heuristic_apps(domain_activity)
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
    http.prepare_content("application/json")
    http.write(jsonc.stringify(build_dashboard_databus()))
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
