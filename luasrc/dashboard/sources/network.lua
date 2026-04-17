local util = require("luci.util")
local config = require("luci.dashboard.sources.config")
local uci_model = require("luci.model.uci")

local M = {}

local function get_cursor()
  return uci_model.cursor()
end

local function read_line(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end

  local value = f:read("*l")
  f:close()
  return value
end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end

  local value = f:read("*a")
  f:close()
  return value
end

function M.summary()
  local uci = get_cursor()
  local wan = util.ubus("network.interface.wan", "status") or {}
  if not wan.up and not (wan["ipv4-address"] and #wan["ipv4-address"] > 0) then
    local dump = util.ubus("network.interface", "dump", {}) or {}
    for _, entry in ipairs(dump.interface or dump.interfaces or {}) do
      local name = entry.interface or ""
      if name ~= "loopback" and name ~= "lan" and not name:match("^lan%d") then
        if entry["ipv4-address"] and #entry["ipv4-address"] > 0 then
          wan = entry
          break
        end
      end
    end
  end

  local wan_ip = ""
  if wan["ipv4-address"] and wan["ipv4-address"][1] then
    wan_ip = wan["ipv4-address"][1].address or ""
  end

  return {
    wanStatus = (wan.up == true or wan_ip ~= "") and "up" or "down",
    wanIp = wan_ip,
    lanIp = uci:get("network", "lan", "ipaddr") or "192.168.1.1",
    dns = wan["dns-server"] or {},
    network_uptime_raw = wan.uptime or 0
  }
end

function M.traffic()
  local wan = util.ubus("network.interface.wan", "status") or {}
  local l3_device = wan.l3_device or wan.device or ""

  if l3_device == "" then
    local dump = util.ubus("network.interface", "dump", {}) or {}
    for _, entry in ipairs(dump.interface or dump.interfaces or {}) do
      local name = entry.interface or ""
      if name ~= "loopback" and name ~= "lan" and not name:match("^lan%d") then
        l3_device = entry.l3_device or entry.device or ""
        if l3_device ~= "" then
          break
        end
      end
    end
  end

  local tx_bytes, rx_bytes = 0, 0
  if l3_device ~= "" then
    local base = "/sys/class/net/" .. l3_device .. "/statistics/"
    tx_bytes = tonumber(read_line(base .. "tx_bytes") or "0") or 0
    rx_bytes = tonumber(read_line(base .. "rx_bytes") or "0") or 0
  end

  return { tx_bytes = tx_bytes, rx_bytes = rx_bytes }
end

function M.devices()
  local devices = {}
  local seen = {}

  local function guess_type(name)
    local normalized = (name or ""):lower()
    if normalized:match("iphone") or normalized:match("ipad") or normalized:match("android") or
      normalized:match("phone") or normalized:match("mobile") or normalized:match("pixel") or
      normalized:match("galaxy") or normalized:match("oneplus") or normalized:match("xiaomi") or
      normalized:match("huawei") or normalized:match("oppo") or normalized:match("vivo") then
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
        local host = (name and name ~= "*") and name or ""
        devices[#devices + 1] = {
          mac = mac,
          ip = ip or "",
          name = host,
          type = guess_type(host),
          active = true
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
          mac = mac,
          ip = ip or "",
          name = "",
          type = "laptop",
          active = true
        }
      end
    end
  end

  return devices
end

local function read_string(cursor, package_name, section, option)
  return tostring(cursor:get(package_name, section, option) or "")
end

local function read_list(cursor, package_name, section, option)
  if type(cursor.get_list) == "function" then
    local values = cursor:get_list(package_name, section, option)
    if type(values) == "table" then
      return values
    end
  end

  local raw = cursor:get(package_name, section, option)
  if type(raw) == "table" then
    return raw
  end
  if type(raw) == "string" and raw ~= "" then
    local values = {}
    for value in raw:gmatch("%S+") do
      values[#values + 1] = value
    end
    return values
  end

  return {}
end

function M.read_lan()
  local cursor = get_cursor()
  local core = config.read_core()

  return {
    proto = read_string(cursor, "network", "lan", "proto"),
    ipaddr = read_string(cursor, "network", "lan", "ipaddr"),
    netmask = read_string(cursor, "network", "lan", "netmask"),
    gateway = read_string(cursor, "network", "lan", "gateway"),
    dns = read_list(cursor, "network", "lan", "dns"),
    lan_ifname = tostring(core.lan_ifname or "")
  }
end

local function apply_lan(cursor, values)
  local dns = type(values.dns) == "table" and values.dns or {}

  cursor:set("network", "lan", "proto", tostring(values.proto or ""))
  cursor:set("network", "lan", "ipaddr", tostring(values.ipaddr or ""))
  cursor:set("network", "lan", "netmask", tostring(values.netmask or ""))
  cursor:set("network", "lan", "gateway", tostring(values.gateway or ""))

  if type(cursor.set_list) == "function" then
    cursor:set_list("network", "lan", "dns", dns)
  else
    cursor:set("network", "lan", "dns", table.concat(dns, " "))
  end
end

function M.write_lan(payload)
  local previous = M.read_lan()
  local cursor = get_cursor()
  local values = type(payload) == "table" and payload or {}

  apply_lan(cursor, values)
  cursor:save("network")
  cursor:commit("network")

  if values.lan_ifname ~= nil then
    local ok, err = pcall(config.write_core, {
      lan_ifname = tostring(values.lan_ifname)
    })

    if not ok or err == false then
      local rollback_cursor = get_cursor()
      apply_lan(rollback_cursor, previous)
      rollback_cursor:save("network")
      rollback_cursor:commit("network")

      error(ok and "dashboard core update failed" or tostring(err))
    end
  end

  return M.read_lan()
end

function M.read_wan()
  local cursor = get_cursor()

  return {
    proto = read_string(cursor, "network", "wan", "proto"),
    ipaddr = read_string(cursor, "network", "wan", "ipaddr"),
    netmask = read_string(cursor, "network", "wan", "netmask"),
    gateway = read_string(cursor, "network", "wan", "gateway"),
    dns = read_list(cursor, "network", "wan", "dns"),
    username = read_string(cursor, "network", "wan", "username"),
    password = read_string(cursor, "network", "wan", "password")
  }
end

function M.write_wan(payload)
  local cursor = get_cursor()
  local values = type(payload) == "table" and payload or {}
  local dns = type(values.dns) == "table" and values.dns or {}

  cursor:set("network", "wan", "proto", tostring(values.proto or ""))
  cursor:set("network", "wan", "ipaddr", tostring(values.ipaddr or ""))
  cursor:set("network", "wan", "netmask", tostring(values.netmask or ""))
  cursor:set("network", "wan", "gateway", tostring(values.gateway or ""))
  cursor:set("network", "wan", "username", tostring(values.username or ""))
  cursor:set("network", "wan", "password", tostring(values.password or ""))

  if type(cursor.set_list) == "function" then
    cursor:set_list("network", "wan", "dns", dns)
  else
    cursor:set("network", "wan", "dns", table.concat(dns, " "))
  end

  cursor:save("network")
  cursor:commit("network")

  return M.read_wan()
end

function M.read_work_mode()
  return {
    work_mode = tostring(config.read_core().work_mode or "")
  }
end

function M.write_work_mode(value)
  local mode = value
  if type(value) == "table" then
    mode = value.work_mode
  end

  config.write_core({
    work_mode = tostring(mode or "")
  })

  return M.read_work_mode()
end

return M
