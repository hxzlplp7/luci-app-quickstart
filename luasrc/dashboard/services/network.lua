local config = require("luci.dashboard.sources.config")
local network = require("luci.dashboard.sources.network")
local validation = require("luci.dashboard.validation")

local M = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function split_dns(value)
  if type(value) == "table" then
    return value
  end

  local text = trim(value)
  local values = {}

  for token in text:gmatch("[^,%s]+") do
    values[#values + 1] = token
  end

  return values
end

local function invalid(code, field, value)
  return nil, code, {
    field = field,
    value = value
  }
end

local function normalize_dns(value)
  local dns = {}

  for _, item in ipairs(split_dns(value)) do
    local addr = trim(item)
    if addr ~= "" then
      if not validation.is_ipv4(addr) then
        return invalid("invalid_dns", "dns", addr)
      end
      dns[#dns + 1] = addr
    end
  end

  return dns
end

local function normalize_work_mode(value)
  local mode = value
  if type(value) == "table" then
    mode = value.work_mode
  end

  mode = trim(mode)
  if mode ~= "0" and mode ~= "1" and mode ~= "2" then
    return invalid("invalid_work_mode", "work_mode", mode)
  end

  return mode
end

function M.validate_lan_payload(payload)
  local source = type(payload) == "table" and payload or {}
  local proto = trim(source.proto)
  local ipaddr = trim(source.ipaddr)
  local netmask = trim(source.netmask)
  local gateway = trim(source.gateway)
  local lan_ifname = trim(source.lan_ifname)
  local dns, dns_err, dns_details = normalize_dns(source.dns)

  if dns == nil then
    return nil, dns_err, dns_details
  end
  if proto ~= "static" and proto ~= "dhcp" then
    return invalid("invalid_proto", "proto", proto)
  end
  if proto == "static" or ipaddr ~= "" then
    if not validation.is_ipv4(ipaddr) then
      return invalid("invalid_ipaddr", "ipaddr", ipaddr)
    end
  end
  if proto == "static" or netmask ~= "" then
    if not validation.is_netmask(netmask) then
      return invalid("invalid_netmask", "netmask", netmask)
    end
  end
  if gateway ~= "" and not validation.is_ipv4(gateway) then
    return invalid("invalid_gateway", "gateway", gateway)
  end
  if lan_ifname == "" or not validation.is_iface_name(lan_ifname) then
    return invalid("invalid_lan_ifname", "lan_ifname", lan_ifname)
  end

  return {
    proto = proto,
    ipaddr = ipaddr,
    netmask = netmask,
    gateway = gateway,
    dns = dns,
    lan_ifname = lan_ifname
  }
end

function M.validate_wan_payload(payload)
  local source = type(payload) == "table" and payload or {}
  local proto = trim(source.proto)
  local username = trim(source.username)
  local password = tostring(source.password or "")
  local dns, dns_err, dns_details = normalize_dns(source.dns)

  if dns == nil then
    return nil, dns_err, dns_details
  end
  if proto ~= "dhcp" and proto ~= "static" and proto ~= "pppoe" then
    return invalid("invalid_proto", "proto", proto)
  end

  local normalized = {
    proto = proto,
    ipaddr = "",
    netmask = "",
    gateway = "",
    dns = dns,
    username = "",
    password = ""
  }

  if proto == "static" then
    normalized.ipaddr = trim(source.ipaddr)
    normalized.netmask = trim(source.netmask)
    normalized.gateway = trim(source.gateway)

    if not validation.is_ipv4(normalized.ipaddr) then
      return invalid("invalid_ipaddr", "ipaddr", normalized.ipaddr)
    end
    if not validation.is_netmask(normalized.netmask) then
      return invalid("invalid_netmask", "netmask", normalized.netmask)
    end
    if normalized.gateway ~= "" and not validation.is_ipv4(normalized.gateway) then
      return invalid("invalid_gateway", "gateway", normalized.gateway)
    end
  elseif proto == "pppoe" then
    if username == "" then
      return invalid("invalid_username", "username", username)
    end

    normalized.username = username
    normalized.password = password
  end

  return normalized
end

function M.get_lan()
  return network.read_lan()
end

function M.set_lan(payload)
  local normalized, err, details = M.validate_lan_payload(payload)
  if not normalized then
    return nil, err, details
  end

  return network.write_lan(normalized)
end

function M.get_wan()
  return network.read_wan()
end

function M.set_wan(payload)
  local normalized, err, details = M.validate_wan_payload(payload)
  if not normalized then
    return nil, err, details
  end

  return network.write_wan(normalized)
end

function M.get_work_mode()
  local payload = network.read_work_mode()
  if type(payload) == "table" and payload.work_mode ~= nil then
    return {
      work_mode = tostring(payload.work_mode)
    }
  end

  return {
    work_mode = tostring(config.read_core().work_mode or "")
  }
end

function M.set_work_mode(value)
  local mode, err, details = normalize_work_mode(value)
  if not mode then
    return nil, err, details
  end

  local payload = network.write_work_mode({
    work_mode = mode
  })
  if type(payload) == "table" and payload.work_mode ~= nil then
    return {
      work_mode = tostring(payload.work_mode)
    }
  end

  return {
    work_mode = tostring(mode)
  }
end

return M
