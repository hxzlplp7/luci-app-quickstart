local http = require("luci.http")
local jsonc = require("luci.jsonc")
local response = require("luci.dashboard.response")
local network = require("luci.dashboard.services.network")

local M = {}

local function write(payload)
  http.prepare_content("application/json")
  http.write(jsonc.stringify(payload))
end

function M.get_lan()
  write(response.ok(network.get_lan()))
end

function M.post_lan()
  local payload, err, details = network.set_lan({
    proto = http.formvalue("proto"),
    ipaddr = http.formvalue("ipaddr"),
    netmask = http.formvalue("netmask"),
    gateway = http.formvalue("gateway"),
    dns = http.formvalue("dns"),
    lan_ifname = http.formvalue("lan_ifname")
  })

  if not payload then
    write(response.fail(err, "invalid lan config", details))
    return
  end

  write(response.ok(payload))
end

function M.get_wan()
  write(response.ok(network.get_wan()))
end

function M.post_wan()
  local payload, err, details = network.set_wan({
    proto = http.formvalue("proto"),
    ipaddr = http.formvalue("ipaddr"),
    netmask = http.formvalue("netmask"),
    gateway = http.formvalue("gateway"),
    dns = http.formvalue("dns"),
    username = http.formvalue("username"),
    password = http.formvalue("password")
  })

  if not payload then
    write(response.fail(err, "invalid wan config", details))
    return
  end

  write(response.ok(payload))
end

function M.get_work_mode()
  write(response.ok(network.get_work_mode()))
end

function M.post_work_mode()
  local payload, err, details = network.set_work_mode({
    work_mode = http.formvalue("work_mode")
  })

  if not payload then
    write(response.fail(err, "invalid work mode", details))
    return
  end

  write(response.ok(payload))
end

return M
