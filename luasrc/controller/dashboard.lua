local http = require("luci.http")
local dispatcher = require("luci.dispatcher")
local jsonc = require("luci.jsonc")
local session = require("luci.dashboard.session")

local PAGE_TEMPLATE = "dashboard/main"
local API_ROUTES = {
  ["GET:/overview"] = { "luci.dashboard.api.overview", "get" }
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

local function dispatch_api()
  local sid = session.require_session()
  if not sid then
    write_error(403, "Forbidden", "forbidden", "forbidden")
    return
  end

  local request_uri = http.getenv("REQUEST_URI") or ""
  local method = http.getenv("REQUEST_METHOD") or "GET"
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

  require("luci.template").render(PAGE_TEMPLATE, {
    prefix = dispatcher.build_url("admin", "dashboard")
  })
end
