local function reset_package(name)
  package.loaded[name] = nil
  package.preload[name] = nil
end

local function map_module(alias, target)
  package.preload[alias] = function()
    return require(target)
  end
end

map_module("luci.dashboard.sources.config", "dashboard.sources.config")
map_module("luci.dashboard.sources.leases", "dashboard.sources.leases")
map_module("luci.dashboard.sources.arp", "dashboard.sources.arp")
map_module("luci.dashboard.sources.nlbwmon", "dashboard.sources.nlbwmon")
map_module("luci.dashboard.services.users", "dashboard.services.users")
map_module("luci.dashboard.api.users", "dashboard.api.users")

do
  local uci_state = {
    sections = {
      alpha = { [".name"] = "alpha", [".type"] = "nickname", mac = "aa:bb:cc:dd:ee:ff", value = "Tablet" },
      beta = { [".name"] = "beta", [".type"] = "nickname", mac = "11:22:33:44:55:66", value = "Laptop" }
    }
  }

  package.preload["luci.model.uci"] = function()
    return {
      cursor = function()
        return {
          foreach = function(_, package_name, section_type, callback)
            assert(package_name == "dashboard", "config source should read dashboard package")
            assert(section_type == "nickname", "config source should read nickname sections")
            for _, section in pairs(uci_state.sections) do
              callback(section)
            end
          end,
          add = function(_, package_name, section_type)
            assert(package_name == "dashboard", "config source should add section in dashboard package")
            assert(section_type == "nickname", "config source should add nickname section")
            uci_state.sections.gamma = { [".name"] = "gamma", [".type"] = "nickname" }
            return "gamma"
          end,
          set = function(_, package_name, section_name, option, value)
            assert(package_name == "dashboard", "unexpected package in set")
            uci_state.sections[section_name][option] = value
          end,
          delete = function(_, package_name, section_name)
            assert(package_name == "dashboard", "unexpected package in delete")
            uci_state.sections[section_name] = nil
          end,
          save = function() end,
          commit = function() end
        }
      end
    }
  end

  reset_package("dashboard.sources.config")
  local config = require("dashboard.sources.config")
  local nicknames = config.read_nicknames()
  assert(nicknames["AA:BB:CC:DD:EE:FF"] == "Tablet", "nickname source should uppercase mac keys")
  assert(nicknames["11:22:33:44:55:66"] == "Laptop", "nickname source should preserve values")

  config.write_nickname("66:55:44:33:22:11", "TV")
  assert(uci_state.sections.gamma.mac == "66:55:44:33:22:11", "write_nickname should store uppercase mac")
  assert(uci_state.sections.gamma.value == "TV", "write_nickname should store value field")
end

do
  reset_package("dashboard.sources.leases")
  local leases = require("dashboard.sources.leases").list_users("tests/fixtures/dhcp.leases")
  assert(#leases == 2, "leases source should parse fixture rows")
  assert(leases[1].mac == "AA:BB:CC:DD:EE:FF", "leases source should uppercase mac addresses")
  assert(leases[1].hostname == "phone", "leases source should preserve hostnames")
  assert(leases[2].hostname == "", "leases source should turn star hostname into empty string")

  reset_package("dashboard.sources.arp")
  local arp = require("dashboard.sources.arp").list_users("tests/fixtures/proc_net_arp.txt")
  assert(#arp == 2, "arp source should ignore incomplete and zero-mac rows")
  assert(arp[1].mac == "AA:BB:CC:DD:EE:FF", "arp source should uppercase mac addresses")
  assert(arp[2].ip == "192.168.1.40", "arp source should keep valid ips")
end

do
  local original_io_popen = io.popen
  local original_os_rename = os.rename

  package.preload["luci.jsonc"] = function()
    return {
      parse = function(payload)
        if payload == "test-json" then
          return {
            {
              mac = "aa:bb:cc:dd:ee:ff",
              rx_bytes = 120,
              tx_bytes = 30
            }
          }
        end
        return nil
      end
    }
  end

  reset_package("dashboard.sources.nlbwmon")
  local nlbwmon = require("dashboard.sources.nlbwmon")
  local empty = nlbwmon.list_users()
  assert(next(empty) == nil, "nlbwmon source should degrade to empty table when unavailable")

  os.rename = function(path, target)
    if path == "/usr/share/nlbwmon" and path == target then
      return true
    end
    return nil
  end

  io.popen = function(cmd)
    if cmd:match("nlbw") then
      local done = false
      return {
        read = function()
          if done then
            return nil
          end
          done = true
          return "test-json"
        end,
        close = function() end
      }
    end
    return nil
  end

  reset_package("dashboard.sources.nlbwmon")
  nlbwmon = require("dashboard.sources.nlbwmon")
  local usage = nlbwmon.list_users()
  assert(usage["AA:BB:CC:DD:EE:FF"].today_down_bytes == 120, "nlbwmon source should parse rx bytes")
  assert(usage["AA:BB:CC:DD:EE:FF"].today_up_bytes == 30, "nlbwmon source should parse tx bytes")
  assert(usage["AA:BB:CC:DD:EE:FF"].supported == true, "nlbwmon source should mark parsed rows as supported")

  io.popen = original_io_popen
  os.rename = original_os_rename
end

do
  package.loaded["luci.dashboard.sources.config"] = {
    read_nicknames = function()
      return {
        ["AA:BB:CC:DD:EE:FF"] = "Tablet"
      }
    end,
    write_nickname = function(mac, value)
      return {
        mac = mac,
        value = value
      }
    end
  }

  package.loaded["luci.dashboard.sources.leases"] = {
    list_users = function()
      return {
        { mac = "AA:BB:CC:DD:EE:FF", ip = "192.168.1.20", hostname = "phone" }
      }
    end
  }

  package.loaded["luci.dashboard.sources.arp"] = {
    list_users = function()
      return {
        { mac = "AA:BB:CC:DD:EE:FF", ip = "192.168.1.20" },
        { mac = "66:55:44:33:22:11", ip = "192.168.1.40" }
      }
    end
  }

  package.loaded["luci.dashboard.sources.nlbwmon"] = {
    list_users = function()
      return {
        ["AA:BB:CC:DD:EE:FF"] = {
          today_up_bytes = 5,
          today_down_bytes = 9,
          supported = true
        }
      }
    end
  }

  reset_package("dashboard.services.users")
  local users = require("dashboard.services.users")
  local page = users.list({ page = 1, page_size = 10 })
  assert(page.page == 1 and page.page_size == 10, "users service should keep paging")
  assert(page.total_num == 2, "users service should merge leases and arp by mac")

  local merged
  for _, item in ipairs(page.list) do
    if item.mac == "AA:BB:CC:DD:EE:FF" then
      merged = item
    end
  end
  assert(merged ~= nil, "users service should keep merged device")
  assert(merged.nickname == "Tablet", "users service should merge nickname")
  assert(merged.hostname == "phone", "users service should merge hostname")
  assert(merged.traffic.today_down_bytes == 9, "users service should merge traffic summary")

  local detail = users.detail("aa:bb:cc:dd:ee:ff")
  assert(detail.device.mac == "AA:BB:CC:DD:EE:FF", "users detail should normalize lookup mac")
  assert(detail.device.nickname == "Tablet", "users detail should keep nickname")
  assert(detail.traffic.today_up_bytes == 5, "users detail should keep traffic data")
  assert(#detail.recent_domains == 0 and #detail.history == 0, "users detail should default empty arrays")

  assert(users.detail("00:11:22:33:44:55") == nil, "users detail should return nil for unknown mac")

  local ok_result, err_code = users.save_remark("invalid", "bad")
  assert(ok_result == nil and err_code == "invalid_mac", "save_remark should validate mac format")
end

do
  local response_body
  local form_state = {}

  package.loaded["luci.http"] = {
    formvalue = function(key)
      return form_state[key]
    end,
    prepare_content = function() end,
    write = function(body)
      response_body = body
    end
  }

  package.loaded["luci.jsonc"] = {
    stringify = function(value)
      return value
    end
  }

  package.loaded["luci.dashboard.services.users"] = {
    list = function(params)
      return {
        page = params.page,
        page_size = params.page_size,
        total_num = 1,
        list = {}
      }
    end,
    detail = function(mac)
      if mac == "AA:BB:CC:DD:EE:FF" then
        return {
          device = { mac = mac },
          traffic = { supported = false },
          recent_domains = {},
          history = {}
        }
      end
      return nil
    end,
    save_remark = function(mac, value)
      if mac ~= "AA:BB:CC:DD:EE:FF" then
        return nil, "invalid_mac"
      end
      return { saved = true, value = value }
    end
  }

  reset_package("dashboard.api.users")
  local api = require("dashboard.api.users")

  form_state = { page = "2", page_size = "15" }
  api.list()
  assert(response_body.ok == true, "users list API should return ok envelope")
  assert(response_body.data.page == 2 and response_body.data.page_size == 15, "users list API should parse paging")

  form_state = { mac = "00:11:22:33:44:55" }
  api.detail()
  assert(response_body.ok == false and response_body.error.code == "not_found", "users detail API should fail when user missing")

  form_state = { mac = "invalid", value = "Desk Phone" }
  api.remark()
  assert(response_body.ok == false and response_body.error.code == "invalid_arg", "users remark API should reject invalid mac")

  form_state = { mac = "AA:BB:CC:DD:EE:FF", value = "Desk Phone" }
  api.remark()
  assert(response_body.ok == true and response_body.data.saved == true, "users remark API should wrap successful save")
  assert(response_body.data.value == "Desk Phone", "users remark API should pass value parameter through")
end

do
  local request_uri = "/admin/dashboard/api/users"
  local request_method = "GET"
  local list_called = false
  local detail_called = false
  local remark_called = false

  _G.entry = function(path, target, title, order)
    return { path = path, target = target, title = title, order = order }
  end

  _G.call = function(name)
    return name
  end

  _G._ = function(value)
    return value
  end

  package.loaded["luci.http"] = {
    getenv = function(name)
      if name == "REQUEST_URI" then
        return request_uri
      end
      if name == "REQUEST_METHOD" then
        return request_method
      end
      if name == "HTTP_X_DASHBOARD_CSRF_TOKEN" then
        return "t"
      end
      return nil
    end,
    prepare_content = function() end,
    write = function() end,
    status = function() end
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

  package.loaded["luci.dashboard.session"] = {
    require_session = function()
      return "sid", { token = "t" }
    end
  }

  package.loaded["luci.dashboard.api.overview"] = {
    get = function() end
  }

  package.loaded["luci.dashboard.api.users"] = {
    list = function()
      list_called = true
    end,
    detail = function()
      detail_called = true
    end,
    remark = function()
      remark_called = true
    end
  }

  reset_package("luci.controller.dashboard")
  local controller = require("luci.controller.dashboard")

  controller.dashboard_dispatch()
  assert(list_called == true, "controller should dispatch users list route")

  request_uri = "/admin/dashboard/api/users/detail?mac=AA:BB:CC:DD:EE:FF"
  controller.dashboard_dispatch()
  assert(detail_called == true, "controller should dispatch users detail route")

  request_method = "POST"
  request_uri = "/admin/dashboard/api/users/remark"
  controller.dashboard_dispatch()
  assert(remark_called == true, "controller should dispatch users remark route")
end
