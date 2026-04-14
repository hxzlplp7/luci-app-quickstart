-- Dashboard Controller
-- 移除冗余分发逻辑，直接使用统一 API 模块

local http = require "luci.http"
local u = require "luci.dashboard.util"

module("luci.controller.dashboard", package.seeall)

function index()
    -- 直接渲染 main 模板，不再通过 home.htm 中转
    entry({"admin", "dashboard"}, template("dashboard/main"), _("Dashboard"), 1).leaf = true
    entry({"admin", "dashboard", "api"}, call("dashboard_api")).leaf = true
end

local routes = {
    ["system_status"]  = "get_system_status",
    ["system_info"]    = "get_system_info",
    ["network_status"] = "get_network_status",
    ["network_traffic"]= "get_traffic",
}

function dashboard_api()
    local sid = u.check_session()
    if not sid then
        http.prepare_content("application/json")
        http.write('{"success":-1001,"error":"Forbidden"}')
        return
    end

    local action = http.getenv("PATH_INFO"):match("/api/([^/]+)")
    local func_name = routes[action]

    if func_name then
        local api = require "luci.dashboard.api"
        if type(api[func_name]) == "function" then
            local ok, err = pcall(api[func_name])
            if not ok then
                http.prepare_content("application/json")
                http.write('{"success":500,"error":"' .. tostring(err):gsub('"', '\\"') .. '"}')
            end
            return
        end
    end

    http.prepare_content("application/json")
    http.write('{"success":404,"error":"Not Found"}')
end
