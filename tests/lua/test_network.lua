local validation = require("luci.dashboard.validation")

assert(validation.is_ipv4("192.168.10.1") == true, "valid ipv4 rejected")
assert(validation.is_ipv4("256.1.1.1") == false, "invalid ipv4 accepted")
assert(validation.is_netmask("255.255.255.0") == true, "valid netmask rejected")
assert(validation.is_netmask("255.255.0.255") == false, "invalid netmask accepted")

local network_state = {
  lan = {
    proto = "static",
    ipaddr = "192.168.1.1",
    netmask = "255.255.255.0",
    gateway = "192.168.1.254",
    dns = { "223.5.5.5", "119.29.29.29" },
    lan_ifname = "br-lan"
  },
  wan = {
    proto = "dhcp",
    ipaddr = "",
    netmask = "",
    gateway = "",
    dns = {},
    username = "",
    password = ""
  },
  work_mode = "0"
}

local core_state = {
  work_mode = "0",
  lan_ifname = "br-lan",
  monitor_device = "wan"
}

package.preload["luci.dashboard.sources.network"] = function()
  return {
    read_lan = function()
      return {
        proto = network_state.lan.proto,
        ipaddr = network_state.lan.ipaddr,
        netmask = network_state.lan.netmask,
        gateway = network_state.lan.gateway,
        dns = network_state.lan.dns,
        lan_ifname = network_state.lan.lan_ifname
      }
    end,
    write_lan = function(payload)
      network_state.lan = {
        proto = payload.proto,
        ipaddr = payload.ipaddr,
        netmask = payload.netmask,
        gateway = payload.gateway,
        dns = payload.dns,
        lan_ifname = payload.lan_ifname
      }
      return {
        proto = payload.proto,
        ipaddr = payload.ipaddr,
        netmask = payload.netmask,
        gateway = payload.gateway,
        dns = payload.dns,
        lan_ifname = payload.lan_ifname
      }
    end,
    read_wan = function()
      return {
        proto = network_state.wan.proto,
        ipaddr = network_state.wan.ipaddr,
        netmask = network_state.wan.netmask,
        gateway = network_state.wan.gateway,
        dns = network_state.wan.dns,
        username = network_state.wan.username,
        password = network_state.wan.password
      }
    end,
    write_wan = function(payload)
      network_state.wan = {
        proto = payload.proto,
        ipaddr = payload.ipaddr,
        netmask = payload.netmask,
        gateway = payload.gateway,
        dns = payload.dns,
        username = payload.username,
        password = payload.password
      }
      return {
        proto = payload.proto,
        ipaddr = payload.ipaddr,
        netmask = payload.netmask,
        gateway = payload.gateway,
        dns = payload.dns,
        username = payload.username,
        password = payload.password
      }
    end,
    read_work_mode = function()
      return {
        work_mode = core_state.work_mode
      }
    end,
    write_work_mode = function(value)
      local mode = value
      if type(value) == "table" then
        mode = value.work_mode
      end

      core_state.work_mode = mode
      return {
        work_mode = mode
      }
    end
  }
end

package.preload["luci.dashboard.sources.config"] = function()
  return {
    read_core = function()
      return {
        work_mode = core_state.work_mode,
        lan_ifname = core_state.lan_ifname,
        monitor_device = core_state.monitor_device
      }
    end,
    write_core = function(values)
      for key, value in pairs(values) do
        core_state[key] = value
      end
      return true
    end
  }
end

local service = require("luci.dashboard.services.network")

local lan_payload, lan_err = service.validate_lan_payload({
  proto = "static",
  ipaddr = "192.168.5.1",
  netmask = "255.255.255.0",
  gateway = "192.168.5.254",
  dns = { "1.1.1.1", "8.8.8.8" },
  lan_ifname = "br-lan"
})
assert(lan_payload ~= nil, "valid lan payload rejected")
assert(lan_err == nil, "valid lan payload returned error")
assert(lan_payload.proto == "static", "lan proto should be preserved")
assert(lan_payload.ipaddr == "192.168.5.1", "lan ipaddr should be preserved")
assert(lan_payload.gateway == "192.168.5.254", "lan gateway should be preserved")
assert(#lan_payload.dns == 2, "lan dns should keep both entries")
assert(lan_payload.lan_ifname == "br-lan", "lan ifname should be preserved")

local saved_lan = service.set_lan({
  proto = "static",
  ipaddr = "192.168.9.1",
  netmask = "255.255.255.0",
  gateway = "192.168.9.254",
  dns = { "4.4.4.4" },
  lan_ifname = "br-lan"
})
assert(saved_lan.proto == "static", "set_lan should return complete lan proto")
assert(saved_lan.gateway == "192.168.9.254", "set_lan should return complete lan gateway")
assert(saved_lan.dns[1] == "4.4.4.4", "set_lan should return complete lan dns")
assert(saved_lan.lan_ifname == "br-lan", "set_lan should return lan ifname")

local invalid_lan, invalid_lan_err, invalid_lan_details = service.validate_lan_payload({
  proto = "static",
  ipaddr = "192.168.5.1",
  netmask = "255.255.255.0",
  gateway = "192.168.5.254",
  dns = { "8.8.8.999" },
  lan_ifname = "br-lan"
})
assert(invalid_lan == nil, "invalid lan payload should fail")
assert(invalid_lan_err == "invalid_dns", "invalid lan dns should report invalid_dns")
assert(invalid_lan_details.field == "dns", "invalid lan error should identify dns")

local wan_payload, wan_err = service.validate_wan_payload({
  proto = "static",
  ipaddr = "10.0.0.2",
  netmask = "255.255.255.0",
  gateway = "10.0.0.1",
  dns = { "1.1.1.1", "8.8.8.8" }
})
assert(wan_payload ~= nil, "valid static wan payload rejected")
assert(wan_err == nil, "valid static wan payload returned error")
assert(#wan_payload.dns == 2, "wan dns should keep both entries")

local saved_wan = service.set_wan({
  proto = "pppoe",
  dns = { "9.9.9.9" },
  username = "dialer",
  password = "secret"
})
assert(saved_wan.proto == "pppoe", "set_wan should return wan proto")
assert(saved_wan.dns[1] == "9.9.9.9", "set_wan should return wan dns")
assert(saved_wan.username == "dialer", "set_wan should return wan username")
assert(saved_wan.password == "secret", "set_wan should return wan password")

local invalid_wan, invalid_wan_err, invalid_wan_details = service.validate_wan_payload({
  proto = "static",
  ipaddr = "10.0.0.2",
  netmask = "255.255.255.0",
  gateway = "10.0.0.1",
  dns = { "1.1.1.999" }
})
assert(invalid_wan == nil, "invalid wan payload should fail")
assert(invalid_wan_err == "invalid_dns", "invalid dns should report invalid_dns")
assert(invalid_wan_details.field == "dns", "invalid wan error should identify dns")

local invalid_pppoe, invalid_pppoe_err, invalid_pppoe_details = service.validate_wan_payload({
  proto = "pppoe",
  username = "dialer",
  password = ""
})
assert(invalid_pppoe == nil, "pppoe without password should fail")
assert(invalid_pppoe_err == "invalid_password", "pppoe without password should report invalid_password")
assert(invalid_pppoe_details.field == "password", "pppoe invalid password should identify password")

local work_mode = service.get_work_mode()
assert(work_mode.work_mode == "0", "initial work mode should come from core config")

local set_mode_payload, set_mode_err = service.set_work_mode({
  work_mode = "2"
})
assert(set_mode_payload ~= nil, "valid work mode should save")
assert(set_mode_err == nil, "valid work mode should not error")
assert(set_mode_payload.work_mode == "2", "work mode payload should preserve 2")
assert(core_state.work_mode == "2", "work mode should persist to config")

local bad_mode, bad_mode_err, bad_mode_details = service.set_work_mode({
  work_mode = "3"
})
assert(bad_mode == nil, "invalid work mode should fail")
assert(bad_mode_err == "invalid_work_mode", "invalid work mode should report invalid_work_mode")
assert(bad_mode_details.field == "work_mode", "invalid work mode should identify field")
