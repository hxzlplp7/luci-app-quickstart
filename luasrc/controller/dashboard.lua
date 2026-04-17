local http = require("luci.http")
local dispatcher = require("luci.dispatcher")
local jsonc = require("luci.jsonc")
local session = require("luci.dashboard.session")

local PAGE_TEMPLATE = "dashboard/main"
local API_ROUTES = {
  ["GET:/overview"] = { "luci.dashboard.api.overview", "get" },
  ["GET:/network/lan"] = { "luci.dashboard.api.network", "get_lan" },
  ["POST:/network/lan"] = { "luci.dashboard.api.network", "post_lan" },
  ["GET:/network/wan"] = { "luci.dashboard.api.network", "get_wan" },
  ["POST:/network/wan"] = { "luci.dashboard.api.network", "post_wan" },
  ["GET:/network/work-mode"] = { "luci.dashboard.api.network", "get_work_mode" },
  ["POST:/network/work-mode"] = { "luci.dashboard.api.network", "post_work_mode" },
  ["GET:/system/config"] = { "luci.dashboard.api.system", "get" },
  ["POST:/system/config"] = { "luci.dashboard.api.system", "post" },
  ["GET:/record/base"] = { "luci.dashboard.api.record", "get" },
  ["POST:/record/base"] = { "luci.dashboard.api.record", "post" },
  ["POST:/record/action"] = { "luci.dashboard.api.record", "action" },
  ["GET:/feature/info"] = { "luci.dashboard.api.feature", "info" },
  ["GET:/feature/classes"] = { "luci.dashboard.api.feature", "classes" },
  ["POST:/feature/upload"] = { "luci.dashboard.api.feature", "upload" },
  ["GET:/feature/status"] = { "luci.dashboard.api.feature", "status" },
  ["GET:/settings/dashboard"] = { "luci.dashboard.api.settings", "get_dashboard" },
  ["POST:/settings/dashboard"] = { "luci.dashboard.api.settings", "post_dashboard" },
  ["GET:/users"] = { "luci.dashboard.api.users", "list" },
  ["GET:/users/detail"] = { "luci.dashboard.api.users", "detail" },
  ["POST:/users/remark"] = { "luci.dashboard.api.users", "remark" }
}
local COMPAT_ROUTES = {
  ["GET:/sysinfo"] = function()
    return require("luci.dashboard.sources.system").read()
  end,
  ["GET:/netinfo"] = function()
    return require("luci.dashboard.sources.network").summary()
  end,
  ["GET:/traffic"] = function()
    return require("luci.dashboard.sources.network").traffic()
  end,
  ["GET:/devices"] = function()
    return require("luci.dashboard.sources.network").devices()
  end,
  ["GET:/domains"] = function()
    return require("luci.dashboard.sources.domains").summary()
  end
}

module("luci.controller.dashboard", package.seeall)

function index()
  entry({ "admin", "dashboard" }, call("dashboard_dispatch"), _("Dashboard"), 0).leaf = true
end

local function write_json(body)
  http.prepare_content("application/json")
  http.write(jsonc.stringify(body))
end

local function write_error(status_code, status_message, code, message)
  http.status(status_code, status_message)
  write_json({
    ok = false,
    error = {
      code = code,
      message = message
    }
  })
end

local function validate_csrf(session_values)
  local request_token = tostring(http.getenv("HTTP_X_DASHBOARD_CSRF_TOKEN") or "")
  local session_token = ""

  if type(session_values) == "table" then
    session_token = tostring(session_values.token or "")
  end

  return session_token ~= "" and request_token == session_token
end

local function dispatch_api()
  local sid, session_values = session.require_session()
  if not sid then
    write_error(403, "Forbidden", "forbidden", "forbidden")
    return
  end

  local request_uri = http.getenv("REQUEST_URI") or ""
  local method = http.getenv("REQUEST_METHOD") or "GET"
  if method ~= "GET" and not validate_csrf(session_values) then
    write_error(403, "Forbidden", "invalid_csrf", "invalid csrf token")
    return
  end

  local path = request_uri:match("/admin/dashboard/api(/.*)") or "/"
  path = path:gsub("%?.*$", "")
  local route_key = method .. ":" .. path
  local compat = COMPAT_ROUTES[route_key]
  local route = API_ROUTES[route_key]

  if compat then
    local ok, result = pcall(compat)
    if not ok then
      write_error(500, "Internal Server Error", "internal_error", tostring(result))
      return
    end

    write_json(result)
    return
  end

  if not route then
    write_error(404, "Not Found", "not_found", "route not found")
    return
  end

  local ok, mod = pcall(require, route[1])
  if not ok then
    write_error(500, "Internal Server Error", "module_load_failed", tostring(mod))
    return
  end

  if type(mod) ~= "table" or type(mod[route[2]]) ~= "function" then
    write_error(500, "Internal Server Error", "handler_not_found", "handler not found")
    return
  end

  local ok_handler, err = pcall(mod[route[2]])
  if not ok_handler then
    write_error(500, "Internal Server Error", "handler_failed", tostring(err))
    return
  end
end

function dashboard_dispatch()
  local uri = http.getenv("REQUEST_URI") or ""
  if uri:match("/admin/dashboard/api") then
    return dispatch_api()
  end

  local _, session_values = session.require_session()

  require("luci.template").render(PAGE_TEMPLATE, {
    prefix = dispatcher.build_url("admin", "dashboard"),
    session_token = type(session_values) == "table" and tostring(session_values.token or "") or ""
  })
end
