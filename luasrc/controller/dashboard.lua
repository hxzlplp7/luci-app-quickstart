-- Dashboard Controller
-- Replaces the original reverse proxy (port 3038) with direct Lua API handlers
-- All API endpoints return JSON: {"success": 200, "result": {...}}

local http = require "luci.http"
local util = require "luci.util"

module("luci.controller.dashboard", package.seeall)

function index()
    entry({"admin", "dashboard"}, template("dashboard/home"), _("Dashboard"), 1).leaf = true
    entry({"dashboard-api"}, call("dashboard_api")).leaf = true
end

-- ========== Session Validation ==========

local function check_session()
    local sdat, sid
    for _, key in ipairs({"sysauth_https", "sysauth_http", "sysauth"}) do
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

-- ========== Route Table ==========

local routes = {
    -- P0: Core Dashboard APIs
    ["GET:/u/network/status/"]         = {"api_network", "status"},
    ["GET:/u/network/statistics/"]     = {"api_network", "statistics"},
    ["GET:/network/device/list/"]      = {"api_network", "device_list"},
    ["GET:/network/port/list/"]        = {"api_network", "port_list"},
    ["GET:/network/interface/config/"] = {"api_network", "interface_config_get"},
    ["POST:/network/interface/config/"]= {"api_network", "interface_config_post"},
    ["POST:/network/checkPublicNet/"]  = {"api_network", "check_public_net"},

    ["GET:/system/status/"]            = {"api_system", "status"},
    ["GET:/u/system/version/"]         = {"api_system", "version"},
    ["POST:/system/reboot/"]           = {"api_system", "reboot"},

    -- Preserved guide APIs used by the remaining dashboard features
    ["GET:/guide/dns-config/"]             = {"api_guide", "dns_config_get"},
    ["POST:/guide/dns-config/"]            = {"api_guide", "dns_config_post"},
    ["GET:/u/guide/ddns/"]                 = {"api_guide", "ddns_get"},
    ["POST:/u/guide/ddns/"]                = {"api_guide", "ddns_post"},
    ["GET:/guide/docker/status/"]          = {"api_guide", "docker_status"},
    ["GET:/guide/docker/partition/list/"]  = {"api_guide", "docker_partition_list"},
    ["POST:/guide/docker/transfer/"]       = {"api_guide", "docker_transfer"},
    ["POST:/guide/docker/switch/"]         = {"api_guide", "docker_switch"},

    -- Download service status
    ["GET:/guide/download-service/status/"] = {"api_guide", "download_service_status"},

    -- P2: NAS basics
    ["GET:/nas/disk/status/"]          = {"api_nas", "disk_status"},
    ["GET:/u/nas/service/status/"]     = {"api_nas", "service_status"},
}

-- ========== API Dispatcher ==========

function dashboard_api()
    -- Validate session
    local sid, sdat = check_session()
    if not sid then
        http.prepare_content("application/json")
        http.write('{"success":-1001,"error":"Forbidden"}')
        return
    end

    -- Parse request
    local request_uri = http.getenv("REQUEST_URI") or ""
    local method = http.getenv("REQUEST_METHOD") or "GET"

    -- Extract API path after "dashboard-api"
    local api_path = request_uri:match("/dashboard%-api(/.*)") or "/"
    -- Remove query string
    api_path = api_path:gsub("%?.*$", "")
    -- Normalize trailing slash
    if not api_path:match("/$") then
        api_path = api_path .. "/"
    end

    -- Lookup route
    local route_key = method .. ":" .. api_path
    local route = routes[route_key]

    if route then
        local module_name = "luci.dashboard." .. route[1]
        local func_name = route[2]

        local ok, mod = pcall(require, module_name)
        if ok and mod and type(mod[func_name]) == "function" then
            local success, err = pcall(mod[func_name])
            if not success then
                http.prepare_content("application/json")
                http.write('{"success":500,"error":"' .. tostring(err):gsub('"', '\\"') .. '"}')
            end
        else
            http.prepare_content("application/json")
            http.write('{"success":500,"error":"Module load failed: ' .. tostring(mod) .. '"}')
        end
    else
        -- Unsupported endpoint: return empty success for graceful degradation
        http.prepare_content("application/json")
        http.write('{"success":200,"result":{}}')
    end
end
