local fs = require "nixio.fs"
local http = require "luci.http"
local sys = require "luci.sys"
local json = require "luci.jsonc"
local util = require "luci.util"
local d = require "luci.dispatcher"

local M = {}

local FEATURE_ROOT = "/etc/appfilter"
local FEATURE_FILE = FEATURE_ROOT .. "/feature.cfg"
local FEATURE_LINK = "/tmp/feature.cfg"
local VERSION_FILE = FEATURE_ROOT .. "/version.txt"
local ICON_DIR = "/www/luci-static/resources/app_icons"
local TMP_ROOT = "/tmp/oaf-upload"
local MAX_SIZE = 32 * 1024 * 1024
local ACTIVE_WINDOW = 3600

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function basename(path)
    local name = tostring(path or ""):gsub("\\", "/"):match("([^/]+)$") or "feature.bin"
    name = name:gsub("[^%w%._%-]", "_")
    if name == "" then
        name = "feature.bin"
    end
    return name
end

local function shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", [['"'"']]) .. "'"
end

local function path_exists(path)
    return fs.access(path) and true or false
end

local function ensure_dir(path)
    return sys.call("mkdir -p " .. shell_quote(path) .. " >/dev/null 2>&1") == 0
end

local function cleanup_tmp()
    sys.call("rm -rf " .. shell_quote(TMP_ROOT) .. " >/dev/null 2>&1")
end

local function read_first_line(path)
    local fp = io.open(path, "r")
    if not fp then
        return nil
    end

    local line = fp:read("*l")
    fp:close()
    return line
end

local function stat_size(path)
    local st = fs.stat(path)
    if st and st.size then
        return tonumber(st.size) or 0
    end
    return 0
end

local function exec_trim(cmd)
    return trim(sys.exec(cmd .. " 2>/dev/null"))
end

local function call_appfilter(method, payload)
    local ok, response = pcall(util.ubus, "appfilter", method, payload or {})
    if ok and type(response) == "table" then
        return response
    end
    return nil
end

local function unwrap_response(resp)
    if type(resp) ~= "table" then
        return {}
    end
    if type(resp.data) == "table" then
        return resp.data
    end
    return resp
end

local function extract_list(resp, ...)
    local data = unwrap_response(resp)
    for _, key in ipairs({...}) do
        if type(data[key]) == "table" then
            return data[key]
        end
    end
    if data[1] ~= nil then
        return data
    end
    return {}
end

local function parse_version_string(raw)
    return tostring(raw or ""):match("(%d+%.%d+%.%d+)") or ""
end

local function split_version(raw)
    local parts = {}
    for num in tostring(raw or ""):gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(num) or 0
    end
    return parts
end

local function compare_versions(left, right)
    local lhs = split_version(left)
    local rhs = split_version(right)
    local max_len = math.max(#lhs, #rhs)

    for i = 1, max_len do
        local a = lhs[i] or 0
        local b = rhs[i] or 0
        if a < b then
            return -1
        end
        if a > b then
            return 1
        end
    end

    return 0
end

local function normalize_domain(value)
    local domain = trim(value):lower()
    if domain == "" then
        return nil
    end

    domain = domain:gsub("^https?://", "")
    domain = domain:gsub("^%*%.", "")
    domain = domain:gsub("/.*$", "")
    domain = domain:gsub(":.*$", "")
    domain = domain:gsub("%.+$", "")

    if domain == "" or not domain:match("[%a]") then
        return nil
    end

    if domain:match("^%d+%.%d+%.%d+%.%d+$") then
        return nil
    end

    if domain:match("in%-addr%.arpa$") or domain == "localhost" then
        return nil
    end

    return domain
end

local function extract_domains_from_line(line)
    local results = {}
    local seen = {}
    local raw = tostring(line or "")
    local patterns = {
        "query[%[%]%w]*%s+([%w%-%.]+)%s+from",
        "reply%s+([%w%-%.]+)%s+is",
        "cached%s+([%w%-%.]+)%s+is",
        "host=([%w%-%.]+)",
        "sni=([%w%-%.]+)",
    }

    for _, pattern in ipairs(patterns) do
        for candidate in raw:gmatch(pattern) do
            local domain = normalize_domain(candidate)
            if domain and not seen[domain] then
                seen[domain] = true
                results[#results + 1] = domain
            end
        end
    end

    for candidate in raw:gmatch("([%w][%w%-]*[%w]?%.[%w%.%-]+)") do
        local domain = normalize_domain(candidate)
        if domain and not seen[domain] then
            seen[domain] = true
            results[#results + 1] = domain
        end
    end

    return results
end

local function table_count(map)
    local total = 0
    for _ in pairs(map or {}) do
        total = total + 1
    end
    return total
end

local function normalize_host_rule(value)
    local host = trim(value):lower()
    if host == "" then
        return nil
    end

    host = host:gsub("^https?://", "")
    host = host:gsub("^%.+", "")
    host = host:gsub("/.*$", "")
    host = host:gsub(":.*$", "")
    host = host:gsub("%s+", "")
    host = host:gsub("%.+$", "")

    if host == "" or host == "*" or host == "-" then
        return nil
    end

    if host:find("%?") or host:find("%^") then
        return nil
    end

    if host:match("^%d+%.%d+%.%d+%.%d+$") then
        return nil
    end

    if not host:match("[%a]") then
        return nil
    end

    return host
end

local function parse_host_rules(blob)
    local hosts = {}
    local seen = {}
    local raw_blob = tostring(blob or "")

    for rule in raw_blob:gmatch("[^,]+") do
        local fields = {}
        local start_at = 1
        while true do
            local idx = rule:find(";", start_at, true)
            if not idx then
                fields[#fields + 1] = rule:sub(start_at)
                break
            end
            fields[#fields + 1] = rule:sub(start_at, idx - 1)
            start_at = idx + 1
        end

        local host_field = trim(fields[4] or "")
        if host_field ~= "" then
            for token in host_field:gmatch("[^|]+") do
                local host = normalize_host_rule(token)
                if host and not seen[host] then
                    seen[host] = true
                    hosts[#hosts + 1] = host
                end
            end
        end
    end

    return hosts
end

local function domain_matches_host(domain, host)
    local normalized_domain = normalize_domain(domain)
    local normalized_host = normalize_host_rule(host)

    if not normalized_domain or not normalized_host then
        return false, 0
    end

    if normalized_host:find("*", 1, true) then
        local wildcard = "^" .. normalized_host:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*") .. "$"
        if normalized_domain:match(wildcard) then
            return true, 200 + #normalized_host
        end
    end

    if normalized_domain == normalized_host then
        return true, 300 + #normalized_host
    end

    if #normalized_domain > #normalized_host then
        if normalized_domain:sub(-(#normalized_host + 1)) == "." .. normalized_host then
            return true, 250 + #normalized_host
        end
    end

    if normalized_domain:find(normalized_host, 1, true) then
        return true, 100 + #normalized_host
    end

    return false, 0
end

local function parse_feature_catalog(path)
    local catalog = {
        path = path,
        version = "",
        format = "",
        app_count = 0,
        apps = {},
        classes = {},
        matchable_apps = {},
    }

    if not path or not path_exists(path) then
        return catalog
    end

    local fp = io.open(path, "r")
    if not fp then
        return catalog
    end

    local current_class = nil
    local current_label = nil

    while true do
        local raw = fp:read("*l")
        if not raw then
            break
        end

        local line = trim(raw)
        if line ~= "" then
            local version = line:match("^#version%s+(.+)$")
            if version then
                catalog.version = trim(version)
            else
                local format = line:match("^#format%s+(.+)$")
                if format then
                    catalog.format = trim(format)
                else
                    local class_code, _, class_label = line:match("^#class%s+([%w_%-]+)%s+(%d+)%s+(.+)$")
                    if class_code then
                        current_class = trim(class_code)
                        current_label = trim(class_label or class_code)
                        catalog.classes[current_class] = current_label
                    elseif current_class and not line:match("^#") then
                        local app_id, app_name, rule_blob = line:match("^(%d+)%s+([^:]+):%[(.*)%]%s*$")
                        if not app_id then
                            app_id, app_name = line:match("^(%d+)%s+([^:]+):")
                            rule_blob = ""
                        end
                        if app_id and app_name then
                            local id = tonumber(app_id)
                            if id then
                                local host_rules = parse_host_rules(rule_blob)
                                local app_entry = {
                                    id = id,
                                    name = trim(app_name),
                                    class = current_class,
                                    class_label = current_label or current_class,
                                    host_rules = host_rules,
                                }
                                catalog.apps[id] = app_entry
                                catalog.app_count = catalog.app_count + 1
                                if #host_rules > 0 then
                                    catalog.matchable_apps[#catalog.matchable_apps + 1] = app_entry
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    fp:close()
    return catalog
end

local function load_feature_catalog()
    local candidates = {
        FEATURE_FILE,
        FEATURE_LINK,
        FEATURE_ROOT .. "/feature_cn.cfg",
    }

    for _, candidate in ipairs(candidates) do
        if path_exists(candidate) then
            return parse_feature_catalog(candidate)
        end
    end

    return parse_feature_catalog(nil)
end

local function get_engine_info()
    local status = call_appfilter("get_oaf_status", {}) or {}
    local data = status.data or status
    local engine_version = parse_version_string(data.engine_version)

    if engine_version == "" then
        engine_version = parse_version_string(read_first_line("/proc/sys/oaf/version"))
    end

    local plugin_version = trim(data.version or "")
    return engine_version, plugin_version, data
end

local function collect_device_macs()
    local macs = {}
    local seen = {}
    local visit_devs = {}

    local visit_raw = call_appfilter("visit_list", {})
    if visit_raw then
        visit_devs = extract_list(visit_raw, "dev_list", "client_list", "devices")
        for _, device in ipairs(visit_devs) do
            local m = (device.mac or device.mac_addr or ""):upper()
            if m ~= "" and not seen[m] then
                seen[m] = true
                macs[#macs + 1] = m
            end
        end
    end

    if #macs == 0 then
        local dev_raw = call_appfilter("dev_list", {}) or call_appfilter("get_client_list", {})
        if dev_raw then
            local list = extract_list(dev_raw, "dev_list", "client_list", "devices")
            for _, dev in ipairs(list) do
                local m = (dev.mac or dev.mac_addr or ""):upper()
                if m ~= "" and not seen[m] then
                    seen[m] = true
                    macs[#macs + 1] = m
                end
            end
        end
    end

    return macs, visit_devs
end

local function icon_url_for(app_id)
    local path = ICON_DIR .. "/" .. tostring(app_id) .. ".png"
    if path_exists(path) then
        return "/luci-static/resources/app_icons/" .. tostring(app_id) .. ".png"
    end
    return "/luci-static/resources/app_icons/default.png"
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
    local domain_clients = {}
    local seq = 0

    for line in pipe:lines() do
        local raw = tostring(line or "")
        local dst_ip = raw:match("dst=([%d%.]+)")
        local src_ip = raw:match("src=([%d%.]+)")
        local bucket = dst_ip and ip_map[dst_ip] or nil

        if bucket then
            local best_domain = nil
            local best_weight = -1
            for domain, weight in pairs(bucket) do
                local score = tonumber(weight) or 0
                if score > best_weight then
                    best_weight = score
                    best_domain = domain
                end
            end

            if best_domain then
                counts[best_domain] = (counts[best_domain] or 0) + 1
                seq = seq + 1
                last_seen[best_domain] = seq

                if src_ip and src_ip ~= "" then
                    local clients = domain_clients[best_domain]
                    if not clients then
                        clients = {}
                        domain_clients[best_domain] = clients
                    end
                    clients[src_ip] = true
                end
            end
        end
    end

    pipe:close()

    for domain, count in pairs(counts) do
        rows[#rows + 1] = {
            domain = domain,
            count = count,
            devices = table_count(domain_clients[domain]),
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

local function build_domain_rows_from_list(domains, limit)
    local rows = {}
    local counts = {}
    local last_seen = {}

    for idx, domain in ipairs(domains or {}) do
        local normalized = normalize_domain(domain)
        if normalized then
            counts[normalized] = (counts[normalized] or 0) + 1
            last_seen[normalized] = idx
        end
    end

    for domain, count in pairs(counts) do
        rows[#rows + 1] = {
            domain = domain,
            count = count,
            devices = 0,
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

local function collect_realtime_domain_rows(limit)
    local domains, ip_map = collect_dnsmasq_activity("logread | grep -iE 'dnsmasq' | tail -n 12000")
    local rows = collect_conntrack_domain_rows(ip_map, limit or 30)
    local source = "conntrack+dnsmasq"

    if #rows == 0 then
        rows = build_domain_rows_from_list(domains, limit or 30)
        if #rows > 0 then
            source = "dnsmasq-logread"
        else
            source = "none"
        end
    end

    return rows, source
end

local function match_domain_to_app(domain, catalog)
    local best_app = nil
    local best_score = -1
    local normalized = normalize_domain(domain)

    if not normalized then
        return nil
    end

    for _, app in ipairs(catalog.matchable_apps or {}) do
        for _, host_rule in ipairs(app.host_rules or {}) do
            local hit, score = domain_matches_host(normalized, host_rule)
            if hit and score > best_score then
                best_app = app
                best_score = score
            end
        end
    end

    return best_app
end

local function collect_realtime_feature_overview(catalog)
    local rows, domain_source = collect_realtime_domain_rows(40)
    if #rows == 0 then
        return {}, {}, domain_source, 0
    end

    local apps = {}
    local by_app = {}
    local class_totals = {}

    for _, row in ipairs(rows) do
        local domain = normalize_domain(row.domain)
        local app = domain and match_domain_to_app(domain, catalog) or nil
        if app then
            local app_id = tonumber(app.id) or 0
            local hits = tonumber(row.count) or 1
            if hits < 1 then
                hits = 1
            end

            local entry = by_app[app_id]
            if not entry then
                entry = {
                    id = app_id,
                    name = trim(app.name or tostring(app_id)),
                    class = trim(app.class or ""),
                    class_label = trim(app.class_label or app.class or ""),
                    hits = 0,
                    time = 0,
                    devices = 0,
                    latest_time = os.time(),
                    last_seen = 0,
                    icon = icon_url_for(app_id),
                    source = "domain-feature",
                }
                by_app[app_id] = entry
                apps[#apps + 1] = entry
            end

            entry.hits = entry.hits + hits
            entry.time = entry.hits
            entry.devices = math.max(entry.devices or 0, tonumber(row.devices) or 0)

            local class_key = entry.class_label ~= "" and entry.class_label or entry.class
            if class_key ~= "" then
                local class_entry = class_totals[class_key]
                if not class_entry then
                    class_entry = {
                        key = class_key,
                        name = class_key,
                        time = 0,
                    }
                    class_totals[class_key] = class_entry
                end
                class_entry.time = class_entry.time + hits
            end
        end
    end

    table.sort(apps, function(a, b)
        if (a.hits or 0) == (b.hits or 0) then
            return (a.name or "") < (b.name or "")
        end
        return (a.hits or 0) > (b.hits or 0)
    end)
    while #apps > 8 do
        table.remove(apps)
    end

    local class_stats = {}
    for _, item in pairs(class_totals) do
        class_stats[#class_stats + 1] = item
    end
    table.sort(class_stats, function(a, b)
        return (a.time or 0) > (b.time or 0)
    end)
    while #class_stats > 6 do
        table.remove(class_stats)
    end

    return apps, class_stats, domain_source, #rows
end

local function collect_usage_overview(catalog)
    local now = os.time()
    local macs, visit_devices = collect_device_macs()
    local recent_apps = {}
    for _, device in ipairs(visit_devices) do
        if type(device) == "table" then
        local device_mac = trim((device.mac or device.mac_addr or "")):upper()
        for _, visit in ipairs(device.visit_info or device.visits or device.app_list or {}) do
            local app_id = tonumber(visit.appid or visit.id)
            local app_info = app_id and catalog.apps[app_id] or nil
            if app_info then
                local entry = recent_apps[app_id] or {
                    id = app_id,
                    name = app_info.name,
                    class = app_info.class,
                    class_label = app_info.class_label,
                    latest_time = 0,
                    devices = 0,
                    _device_seen = {},
                }

                local latest_time = tonumber(visit.latest_time or visit.lt or 0) or 0
                if latest_time > entry.latest_time then
                    entry.latest_time = latest_time
                end

                if device_mac ~= "" then
                    if not entry._device_seen[device_mac] then
                        entry._device_seen[device_mac] = true
                        entry.devices = (entry.devices or 0) + 1
                    end
                else
                    entry.devices = (entry.devices or 0) + 1
                end

                if app_id then
                    recent_apps[app_id] = entry
                end
            end
        end
        end -- if type(device) == "table"
    end

    local usage_by_app = {}
    local class_totals = {}

    for _, mac in ipairs(macs) do
        local visit_time_raw = call_appfilter("dev_visit_time", { mac = mac })
        local visit_time_list = visit_time_raw and extract_list(visit_time_raw, "list", "app_list", "apps") or {}
        for _, item in ipairs(visit_time_list) do
            local app_id = tonumber(item.id)
            local total_time = tonumber(item.t or item.time or item.total_time) or 0
            local app_info = app_id and catalog.apps[app_id] or nil

            if app_id and total_time > 0 then
                local entry = usage_by_app[app_id] or {
                    id = app_id,
                    name = trim(item.name or (app_info and app_info.name) or tostring(app_id)),
                    class = app_info and app_info.class or "",
                    class_label = app_info and app_info.class_label or "",
                    time = 0,
                }

                entry.time = entry.time + total_time
                usage_by_app[app_id] = entry
            end
        end

        local class_time_raw = call_appfilter("app_class_visit_time", { mac = mac })
        local class_time_list = class_time_raw and extract_list(class_time_raw, "class_list", "class_time_list", "classes") or {}
        for _, item in ipairs(class_time_list) do
            local key = trim(item.name or item.type or "")
            local total_time = tonumber(item.visit_time) or 0

            if key ~= "" and total_time > 0 then
                local entry = class_totals[key] or {
                    key = key,
                    name = trim(item.name or key),
                    time = 0,
                }

                entry.time = entry.time + total_time
                class_totals[key] = entry
            end
        end
    end

    if next(class_totals) == nil then
        for _, item in pairs(usage_by_app) do
            local key = trim(item.class_label ~= "" and item.class_label or item.class)
            if key ~= "" and item.time > 0 then
                local entry = class_totals[key] or {
                    key = key,
                    name = key,
                    time = 0,
                }

                entry.time = entry.time + item.time
                class_totals[key] = entry
            end
        end
    end

    local active_apps = {}
    for app_id, item in pairs(recent_apps) do
        local usage = usage_by_app[app_id]
        item.time = usage and usage.time or 0
        item.icon = icon_url_for(app_id)
        item.last_seen = math.max(0, now - (item.latest_time or 0))
        item._device_seen = nil
        active_apps[#active_apps + 1] = item
    end

    table.sort(active_apps, function(a, b)
        if (a.latest_time or 0) == (b.latest_time or 0) then
            if (a.time or 0) == (b.time or 0) then
                return (a.devices or 0) > (b.devices or 0)
            end
            return (a.time or 0) > (b.time or 0)
        end
        return (a.latest_time or 0) > (b.latest_time or 0)
    end)

    local recent_only = {}
    for _, item in ipairs(active_apps) do
        if (item.latest_time or 0) >= (now - ACTIVE_WINDOW) then
            recent_only[#recent_only + 1] = item
        end
    end

    if #recent_only > 0 then
        active_apps = recent_only
    else
        active_apps = {}
        for app_id, item in pairs(usage_by_app) do
            item.icon = icon_url_for(app_id)
            item.devices = recent_apps[app_id] and recent_apps[app_id].devices or 0
            item.last_seen = recent_apps[app_id] and math.max(0, now - (recent_apps[app_id].latest_time or 0)) or nil
            active_apps[#active_apps + 1] = item
        end

        table.sort(active_apps, function(a, b)
            return (a.time or 0) > (b.time or 0)
        end)
    end

    while #active_apps > 8 do
        table.remove(active_apps)
    end

    local class_stats = {}
    for _, item in pairs(class_totals) do
        class_stats[#class_stats + 1] = item
    end

    table.sort(class_stats, function(a, b)
        return (a.time or 0) > (b.time or 0)
    end)

    while #class_stats > 6 do
        table.remove(class_stats)
    end

    return active_apps, class_stats
end

local function find_archive_candidate(dir, engine_version)
    local output = sys.exec(
        "find " .. shell_quote(dir) .. " -type f \\( -name '*.bin' -o -name '*.tar.gz' -o -name '*.tgz' \\) 2>/dev/null"
    )

    local normal = {}
    local compat = {}

    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local path = trim(line)
        local lower = path:lower()
        if lower ~= "" then
            if lower:match("compat%.bin$") or lower:match("compat%.tar%.gz$") or lower:match("compat%.tgz$") then
                compat[#compat + 1] = path
            else
                normal[#normal + 1] = path
            end
        end
    end

    table.sort(normal)
    table.sort(compat)

    local prefer_compat = engine_version ~= "" and compare_versions(engine_version, "6.1.4") < 0
    if prefer_compat then
        return compat[1] or normal[1]
    end

    return normal[1] or compat[1]
end

local function unpack_zip(zip_path, out_dir)
    local commands = {
        "unzip -oq " .. shell_quote(zip_path) .. " -d " .. shell_quote(out_dir) .. " >/dev/null 2>&1",
        "busybox unzip -o " .. shell_quote(zip_path) .. " -d " .. shell_quote(out_dir) .. " >/dev/null 2>&1",
        "bsdtar -xf " .. shell_quote(zip_path) .. " -C " .. shell_quote(out_dir) .. " >/dev/null 2>&1",
    }

    for _, command in ipairs(commands) do
        if sys.call(command) == 0 then
            return true
        end
    end

    return false
end

local function extract_bundle(archive_path, out_dir)
    local commands = {
        "tar -xzf " .. shell_quote(archive_path) .. " -C " .. shell_quote(out_dir) .. " >/dev/null 2>&1",
        "busybox tar -xzf " .. shell_quote(archive_path) .. " -C " .. shell_quote(out_dir) .. " >/dev/null 2>&1",
    }

    for _, command in ipairs(commands) do
        if sys.call(command) == 0 then
            return true
        end
    end

    return false
end

local function locate_payload(out_dir)
    local feature_cfg = exec_trim("find " .. shell_quote(out_dir) .. " -type f -name 'feature.cfg' | head -n 1")
    local app_icons = exec_trim("find " .. shell_quote(out_dir) .. " -type d -name 'app_icons' | head -n 1")
    return feature_cfg, app_icons
end

local function copy_payload(feature_cfg, app_icons)
    if not ensure_dir(FEATURE_ROOT) then
        return false
    end

    if sys.call("cp " .. shell_quote(feature_cfg) .. " " .. shell_quote(FEATURE_FILE) .. " >/dev/null 2>&1") ~= 0 then
        return false
    end

    if path_exists(FEATURE_LINK) then
        sys.call("cp " .. shell_quote(feature_cfg) .. " " .. shell_quote(FEATURE_LINK) .. " >/dev/null 2>&1")
    end

    if app_icons ~= "" and path_exists(app_icons) then
        ensure_dir(ICON_DIR)
        sys.call("cp -fpR " .. shell_quote(app_icons .. "/.") .. " " .. shell_quote(ICON_DIR) .. " >/dev/null 2>&1")
    end

    return true
end

local function reload_oaf()
    local commands = {
        "killall -SIGUSR1 oafd >/dev/null 2>&1",
        "/etc/init.d/appfilter restart >/dev/null 2>&1",
        "/etc/init.d/oaf restart >/dev/null 2>&1",
    }

    for _, command in ipairs(commands) do
        if sys.call(command) == 0 then
            return true
        end
    end

    return false
end

local function build_status_response()
    local catalog = load_feature_catalog()
    local engine_version, plugin_version, data = get_engine_info()
    local active_apps, class_stats, domain_source, realtime_domain_count = collect_realtime_feature_overview(catalog)
    local active_source = "domain-feature:" .. (domain_source or "none")

    if (realtime_domain_count or 0) <= 0 then
        active_apps, class_stats = collect_usage_overview(catalog)
        active_source = "appfilter-usage"
    end
    local current_version = catalog.version

    if current_version == "" then
        current_version = trim(read_first_line(VERSION_FILE))
    end

    if current_version == "" then
        current_version = "20240101 (内置)"
    end

    local engine = "OpenAppFilter"
    if plugin_version ~= "" then
        engine = engine .. " " .. plugin_version
    elseif engine_version ~= "" then
        engine = engine .. " " .. engine_version
    end

    return {
        success = true,
        available = (catalog.app_count > 0) or (#active_apps > 0) or (#class_stats > 0),
        status = tonumber(data.engine_status or data.enable or 0) == 1 and "running" or "stopped",
        current_version = current_version,
        feature_format = catalog.format,
        app_count = catalog.app_count,
        engine = engine,
        engine_version = engine_version,
        enabled = tonumber(data.enable or 0) == 1,
        active_source = active_source or "none",
        active_apps = active_apps,
        class_stats = class_stats,
        last_update = os.date("%Y-%m-%d %H:%M:%S"),
    }
end

M.get_status_data = function()
    return build_status_response()
end

M.action_status = function()
    http.prepare_content("application/json")
    http.write(json.stringify(build_status_response()))
end

M.api_oaf_status = M.action_status

M.action_upload = function()
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        http.status(405, "Method Not Allowed")
        http.prepare_content("application/json")
        http.write(json.stringify({
            success = false,
            message = "Method Not Allowed",
        }))
        return
    end

    -- 前置 CSRF 校验：从 URL 查询参数中读取 token，在解析 multipart body 之前完成验证
    local qs_token = trim(http.getenv("QUERY_STRING") or ""):match("token=([^&]+)")
    qs_token = qs_token and util.urldecode(qs_token) or ""
    local expected = trim((d.context and d.context.authtoken) or "")
    if expected == "" or qs_token ~= expected then
        http.status(403, "Forbidden")
        http.prepare_content("application/json")
        http.write(json.stringify({
            success = false,
            message = "非法请求，CSRF Token 验证失败。",
        }))
        return
    end

    cleanup_tmp()
    ensure_dir(TMP_ROOT)

    local upload_name = nil
    local upload_path = nil
    local upload_fd = nil
    local upload_size = 0
    local upload_error = nil

    http.setfilehandler(function(meta, chunk, eof)
        if upload_error then
            return
        end

        if meta and meta.name == "file" and not upload_path then
            upload_name = basename(meta.file)
            upload_path = TMP_ROOT .. "/" .. upload_name
            upload_fd = io.open(upload_path, "w")
            if not upload_fd then
                upload_error = "无法创建临时文件。"
                return
            end
        end

        if upload_fd and chunk and #chunk > 0 then
            upload_size = upload_size + #chunk
            if upload_size > MAX_SIZE then
                upload_error = "上传文件过大，请选择 32MB 以内的特征包。"
                upload_fd:close()
                upload_fd = nil
                if upload_path then
                    sys.call("rm -f " .. shell_quote(upload_path) .. " >/dev/null 2>&1")
                end
                return
            end
            upload_fd:write(chunk)
        end

        if eof and upload_fd then
            upload_fd:close()
            upload_fd = nil
        end
    end)

    http.formvalue("file")
    http.prepare_content("application/json")

    if upload_error then
        cleanup_tmp()
        http.write(json.stringify({
            success = false,
            message = upload_error,
        }))
        return
    end

    if not upload_path or not path_exists(upload_path) then
        cleanup_tmp()
        http.write(json.stringify({
            success = false,
            message = "未接收到上传文件。",
        }))
        return
    end

    upload_size = stat_size(upload_path)
    if upload_size <= 0 then
        cleanup_tmp()
        http.write(json.stringify({
            success = false,
            message = "上传文件为空。",
        }))
        return
    end

    if upload_size > MAX_SIZE then
        cleanup_tmp()
        http.write(json.stringify({
            success = false,
            message = "上传文件过大，请选择 32MB 以内的特征包。",
        }))
        return
    end

    local stage_dir = TMP_ROOT .. "/stage"
    local payload_dir = TMP_ROOT .. "/payload"
    ensure_dir(stage_dir)
    ensure_dir(payload_dir)

    local archive_path = upload_path
    local lower_name = tostring(upload_name or ""):lower()

    if lower_name:match("%.zip$") then
        if not unpack_zip(upload_path, stage_dir) then
            cleanup_tmp()
            http.write(json.stringify({
                success = false,
                message = "zip 包解压失败，系统缺少 unzip/bsdtar 或压缩包已损坏。",
            }))
            return
        end

        local engine_version = get_engine_info()
        archive_path = find_archive_candidate(stage_dir, engine_version)
        if not archive_path then
            cleanup_tmp()
            http.write(json.stringify({
                success = false,
                message = "zip 包里没有找到可用的 .bin 特征库文件。",
            }))
            return
        end
    end

    if not extract_bundle(archive_path, payload_dir) then
        cleanup_tmp()
        http.write(json.stringify({
            success = false,
            message = "特征库解包失败，请上传官网提供的 .bin 或 zip 包。",
        }))
        return
    end

    local feature_cfg, app_icons = locate_payload(payload_dir)
    if feature_cfg == "" then
        cleanup_tmp()
        http.write(json.stringify({
            success = false,
            message = "解包成功，但没有找到 feature.cfg。",
        }))
        return
    end

    local extracted_catalog = parse_feature_catalog(feature_cfg)
    if extracted_catalog.version == "" then
        cleanup_tmp()
        http.write(json.stringify({
            success = false,
            message = "特征库格式不正确，缺少版本标记。",
        }))
        return
    end

    if not copy_payload(feature_cfg, app_icons) then
        cleanup_tmp()
        http.write(json.stringify({
            success = false,
            message = "写入特征库失败，请检查 /etc/appfilter 是否可写。",
        }))
        return
    end

    fs.writefile(VERSION_FILE, extracted_catalog.version .. "\n")
    reload_oaf()
    cleanup_tmp()

    http.write(json.stringify({
        success = true,
        message = "特征库更新成功。",
        current_version = extracted_catalog.version,
        app_count = extracted_catalog.app_count,
    }))
end

M.api_oaf_upload = M.action_upload

return M
