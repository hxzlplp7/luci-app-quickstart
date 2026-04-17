local state = {
  network = {
    lan = {
      proto = "static",
      ipaddr = "192.168.1.1",
      netmask = "255.255.255.0",
      gateway = "192.168.1.254",
      dns = { "223.5.5.5" }
    }
  },
  dashboard = {
    core = {
      lan_ifname = "br-lan",
      work_mode = "0"
    }
  },
  fail_dashboard_write = false
}

package.preload["luci.util"] = function()
  return {
    ubus = function()
      return {}
    end
  }
end

package.preload["luci.dashboard.sources.config"] = function()
  return {
    read_core = function()
      return {
        lan_ifname = state.dashboard.core.lan_ifname,
        work_mode = state.dashboard.core.work_mode
      }
    end,
    write_core = function(values)
      if state.fail_dashboard_write then
        error("dashboard commit failed")
      end

      for key, value in pairs(values) do
        state.dashboard.core[key] = value
      end

      return true
    end
  }
end

package.preload["luci.model.uci"] = function()
  local function cursor()
    return {
      get = function(_, package_name, section, option)
        local package_data = state[package_name]
        local section_data = package_data and package_data[section]
        if not section_data then
          return nil
        end

        return section_data[option]
      end,
      get_list = function(_, package_name, section, option)
        local value = state[package_name][section][option]
        if type(value) == "table" then
          local copy = {}
          for index, item in ipairs(value) do
            copy[index] = item
          end
          return copy
        end

        return nil
      end,
      set = function(_, package_name, section, option, value)
        state[package_name][section][option] = value
      end,
      set_list = function(_, package_name, section, option, value)
        local copy = {}
        for index, item in ipairs(value or {}) do
          copy[index] = item
        end
        state[package_name][section][option] = copy
      end,
      save = function() end,
      commit = function() end
    }
  end

  return {
    cursor = cursor
  }
end

local network = require("dashboard.sources.network")

local updated = network.write_lan({
  proto = "static",
  ipaddr = "192.168.9.1",
  netmask = "255.255.255.0",
  gateway = "192.168.9.254",
  dns = { "1.1.1.1", "8.8.8.8" },
  lan_ifname = "br-home"
})
assert(updated.ipaddr == "192.168.9.1", "write_lan should return updated network ipaddr")
assert(updated.lan_ifname == "br-home", "write_lan should return updated lan_ifname")

state.fail_dashboard_write = true

local ok, err = pcall(network.write_lan, {
  proto = "static",
  ipaddr = "10.0.0.1",
  netmask = "255.255.255.0",
  gateway = "10.0.0.254",
  dns = { "9.9.9.9" },
  lan_ifname = "br-bad"
})

assert(ok == false, "write_lan should fail when dashboard write fails")
assert(type(err) == "string" and err:match("dashboard commit failed"), "write_lan should surface dashboard failure")
assert(state.network.lan.ipaddr == "192.168.9.1", "write_lan should roll back network ipaddr on dashboard failure")
assert(state.network.lan.gateway == "192.168.9.254", "write_lan should roll back network gateway on dashboard failure")
assert(state.network.lan.dns[1] == "1.1.1.1", "write_lan should roll back network dns on dashboard failure")
assert(state.dashboard.core.lan_ifname == "br-home", "write_lan should keep previous lan_ifname on dashboard failure")
