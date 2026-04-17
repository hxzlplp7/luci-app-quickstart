package.loaded["luci.dashboard.sources.system"] = {
  read = function()
    return {
      model = "Test Router",
      firmware = "OpenWrt",
      kernel = "6.6",
      uptime_raw = 12,
      cpuUsage = 3,
      memUsage = 4,
      hasSamba4 = true
    }
  end
}

package.loaded["luci.dashboard.sources.network"] = {
  summary = function()
    return {
      wanStatus = "up",
      wanIp = "1.2.3.4",
      lanIp = "192.168.1.1",
      dns = { "8.8.8.8" },
      network_uptime_raw = 10
    }
  end,
  traffic = function()
    return { tx_bytes = 100, rx_bytes = 200 }
  end,
  devices = function()
    return {
      { mac = "AA:BB:CC:DD:EE:FF", ip = "192.168.1.10", name = "phone", active = true }
    }
  end
}

package.loaded["luci.dashboard.sources.domains"] = {
  summary = function()
    return { source = "dnsmasq", top = { { domain = "example.com", count = 3 } }, recent = {} }
  end
}

package.loaded["luci.dashboard.capabilities"] = {
  detect = function()
    return { nlbwmon = false, domain_logs = true, feature_library = false }
  end
}

local overview = require("luci.dashboard.services.overview")
local payload = overview.build()

assert(payload.system.model == "Test Router", "missing system payload")
assert(payload.network.wanIp == "1.2.3.4", "missing network payload")
assert(payload.traffic.rx_bytes == 200, "missing traffic payload")
assert(payload.devices[1].mac == "AA:BB:CC:DD:EE:FF", "missing devices payload")
assert(payload.domains.source == "dnsmasq", "missing domains payload")
assert(payload.capabilities.domain_logs == true, "missing capabilities payload")

local overview_body
package.loaded["luci.dashboard.services.overview"] = {
  build = function()
    return { sample = "payload" }
  end
}

package.loaded["luci.http"] = {
  prepare_content = function() end,
  write = function(body)
    overview_body = body
  end
}

package.loaded["luci.jsonc"] = {
  stringify = function(value)
    return value
  end
}

package.loaded["luci.dashboard.api.overview"] = nil
require("luci.dashboard.api.overview").get()
assert(overview_body.ok == true, "overview API should return ok envelope")
assert(overview_body.data.sample == "payload", "overview API should wrap data payload")

local registered = {}
local status_code
local status_text
local response_body
local prepared_content
local rendered_template
local rendered_prefix
local request_uri = "/admin/dashboard/api/overview"
local request_method = "GET"
local overview_called = false

_G.entry = function(path, target, title, order)
  local node = { path = path, target = target, title = title, order = order }
  registered[#registered + 1] = node
  return node
end

_G.call = function(name)
  return name
end

_G._ = function(value)
  return value
end

local function reset_http_capture()
  status_code = nil
  status_text = nil
  response_body = nil
  prepared_content = nil
end

package.loaded["luci.dashboard.sources.system"] = {
  read = function()
    return {
      model = "Compat Router",
      firmware = "OpenWrt Compat",
      kernel = "6.6.1",
      uptime_raw = 42,
      cpuUsage = 7,
      memUsage = 8,
      temp = 33,
      systime_raw = 123456,
      hasSamba4 = true
    }
  end
}

package.loaded["luci.dashboard.sources.network"] = {
  summary = function()
    return {
      wanStatus = "up",
      wanIp = "1.2.3.4",
      lanIp = "192.168.1.1",
      dns = { "8.8.8.8" },
      network_uptime_raw = 10
    }
  end,
  traffic = function()
    return { tx_bytes = 100, rx_bytes = 200 }
  end,
  devices = function()
    return {
      { mac = "AA:BB:CC:DD:EE:FF", ip = "192.168.1.10", name = "phone", active = true }
    }
  end
}

package.loaded["luci.dashboard.sources.domains"] = {
  summary = function()
    return {
      source = "dnsmasq",
      top = { { domain = "example.com", count = 3 } },
      recent = { { domain = "recent.example", count = 1 } }
    }
  end
}

package.loaded["luci.http"] = {
  getenv = function(name)
    if name == "REQUEST_URI" then
      return request_uri
    end
    if name == "REQUEST_METHOD" then
      return request_method
    end
    return nil
  end,
  status = function(code, text)
    status_code = code
    status_text = text
  end,
  prepare_content = function(content_type)
    prepared_content = content_type
  end,
  write = function(body)
    response_body = body
  end
}

package.loaded["luci.jsonc"] = {
  stringify = function(value)
    return value
  end
}

package.loaded["luci.dispatcher"] = {
  build_url = function()
    return "/admin/dashboard"
  end
}

package.loaded["luci.template"] = {
  render = function(template, context)
    rendered_template = template
    rendered_prefix = context.prefix
  end
}

package.loaded["luci.dashboard.session"] = {
  require_session = function()
    return "sid", { token = "t" }
  end
}

package.loaded["luci.dashboard.api.overview"] = {
  get = function()
    overview_called = true
  end
}

package.loaded["luci.controller.dashboard"] = nil
local controller = require("luci.controller.dashboard")
controller.index()

assert(#registered == 1, "legacy dashboard-api route should be removed")
assert(table.concat(registered[1].path, "/") == "admin/dashboard", "dashboard page route missing")

reset_http_capture()
request_uri = "/admin/dashboard/api/overview"
controller.dashboard_dispatch()
assert(overview_called == true, "overview route should dispatch modular API")

reset_http_capture()
request_uri = "/admin/dashboard/api/netinfo"
controller.dashboard_dispatch()
assert(status_code == nil, "compat netinfo route should not 404")
assert(prepared_content == "application/json", "compat netinfo route should write json")
assert(response_body.wanIp == "1.2.3.4", "compat netinfo route should return bare network payload")

reset_http_capture()
request_uri = "/admin/dashboard/api/sysinfo"
controller.dashboard_dispatch()
assert(response_body.hasSamba4 == true, "compat sysinfo route should include hasSamba4")

reset_http_capture()
request_uri = "/admin/dashboard/api/traffic"
controller.dashboard_dispatch()
assert(response_body.rx_bytes == 200, "compat traffic route should return traffic payload")

reset_http_capture()
request_uri = "/admin/dashboard/api/devices"
controller.dashboard_dispatch()
assert(response_body[1].mac == "AA:BB:CC:DD:EE:FF", "compat devices route should return devices payload")

reset_http_capture()
request_uri = "/admin/dashboard/api/domains"
controller.dashboard_dispatch()
assert(response_body.source == "dnsmasq", "compat domains route should return domains payload")

reset_http_capture()
request_uri = "/admin/dashboard/api/missing"
controller.dashboard_dispatch()
assert(status_code == 404 and status_text == "Not Found", "unknown route should return 404")
assert(response_body.ok == false and response_body.error.code == "not_found", "unknown route should return error envelope")

request_uri = "/admin/dashboard"
controller.dashboard_dispatch()
assert(rendered_template == "dashboard/main", "dashboard page should render main template")
assert(rendered_prefix == "/admin/dashboard", "dashboard page should pass prefix to template")

local real_io_open = io.open
local real_io_popen = io.popen

local function read_fixture(path)
  local f = assert(real_io_open(path, "r"), "missing fixture: " .. path)
  local content = f:read("*a")
  f:close()
  return content
end

local openclash_fixture = read_fixture("tests/fixtures/openclash.log")
local dnsmasq_fixture = read_fixture("tests/fixtures/dnsmasq.log")

local function make_pipe(content)
  local lines = {}
  for line in content:gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  local index = 0

  return {
    lines = function()
      return function()
        index = index + 1
        return lines[index]
      end
    end,
    close = function() end
  }
end

local function run_domains_summary(with_openclash)
  local ok, result = pcall(function()
    io.open = function(path, mode)
      if path == "/tmp/openclash.log" then
        if with_openclash then
          return { close = function() end }
        end
        return nil
      end
      return real_io_open(path, mode)
    end

    io.popen = function(cmd)
      if with_openclash then
        assert(cmd:match("openclash"), "expected openclash command")
        return make_pipe(openclash_fixture)
      end
      assert(cmd:match("dnsmasq"), "expected dnsmasq command")
      return make_pipe(dnsmasq_fixture)
    end

    package.loaded["luci.dashboard.sources.domains"] = nil
    return require("luci.dashboard.sources.domains").summary()
  end)

  io.open = real_io_open
  io.popen = real_io_popen
  package.loaded["luci.dashboard.sources.domains"] = nil
  assert(ok, result)
  return result
end

local function has_domain(entries, domain, expected_count)
  for _, entry in ipairs(entries) do
    if entry.domain == domain and (expected_count == nil or entry.count == expected_count) then
      return true
    end
  end
  return false
end

local openclash_summary = run_domains_summary(true)
assert(openclash_summary.source == "openclash", "openclash fixture should select openclash parser")
assert(has_domain(openclash_summary.top, "example.com"), "openclash fixture should parse example.com")
assert(has_domain(openclash_summary.recent, "github.com"), "openclash fixture should parse github.com recent entry")

local dnsmasq_summary = run_domains_summary(false)
assert(dnsmasq_summary.source == "dnsmasq", "dnsmasq fixture should select dnsmasq parser")
assert(has_domain(dnsmasq_summary.top, "example.org", 2), "dnsmasq fixture should count example.org query and reply")
assert(has_domain(dnsmasq_summary.recent, "downloads.openwrt.org", 1), "dnsmasq fixture should parse recent domains")
