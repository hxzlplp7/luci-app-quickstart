---@diagnostic disable: duplicate-set-field

local function reset_package(name)
  package.loaded[name] = nil
  package.preload[name] = nil
end

local function map_module(alias, target)
  package.preload[alias] = function()
    return require(target)
  end
end

map_module("luci.dashboard.sources.record_store", "dashboard.sources.record_store")
map_module("luci.dashboard.services.record", "dashboard.services.record")
map_module("luci.dashboard.api.record", "dashboard.api.record")

do
  local cursor_state = {
    values = {
      enable = "0",
      record_time = "7",
      app_valid_time = "5",
      history_data_size = "128",
      history_data_path = "/tmp/dashboard/history"
    },
    committed = false
  }
  local fs_state = {
    exists = {
      ["/tmp/dashboard/history"] = true,
      ["/tmp/dashboard/history/day-1.json"] = true,
      ["/tmp/dashboard/history/day-2.json"] = true,
      ["/tmp/dashboard/history.json"] = true,
      ["/tmp/dashboard/link-out"] = true,
      ["/tmp/dashboard/history/link-child"] = true,
      ["/tmp/dashboard/broken-link"] = true
    },
    dirs = {
      ["/tmp/dashboard/history"] = { "day-1.json", "day-2.json" }
    },
    stats = {
      ["/tmp/dashboard/history"] = { type = "dir" },
      ["/tmp/dashboard/history/day-1.json"] = { type = "file" },
      ["/tmp/dashboard/history/day-2.json"] = { type = "file" },
      ["/tmp/dashboard/history.json"] = { type = "file" },
      ["/tmp/dashboard/history/link-child"] = { type = "dir" },
      ["/tmp/dashboard/broken-link"] = { type = "link" },
      ["/etc/passwd"] = { type = "file" }
    },
    realpaths = {
      ["/tmp/dashboard/link-out"] = "/etc/passwd",
      ["/tmp/dashboard/history/link-child"] = "/etc/passwd"
    },
    removed = {}
  }

  package.preload["luci.model.uci"] = function()
    return {
      cursor = function()
        return {
          get = function(_, config_name, section_name, option)
            assert(config_name == "dashboard", "record store should read dashboard config")
            assert(section_name == "record", "record store should use record section")
            return cursor_state.values[option]
          end,
          set = function(_, config_name, section_name, option, value)
            assert(config_name == "dashboard", "record store should write dashboard config")
            assert(section_name == "record", "record store should write record section")
            cursor_state.values[option] = tostring(value)
          end,
          save = function(_, config_name)
            assert(config_name == "dashboard", "record store should save dashboard config")
          end,
          commit = function(_, config_name)
            assert(config_name == "dashboard", "record store should commit dashboard config")
            cursor_state.committed = true
          end
        }
      end
    }
  end

  package.preload["nixio.fs"] = function()
    return {
      access = function(path)
        return fs_state.exists[path] == true
      end,
      dir = function(path)
        local entries = fs_state.dirs[path] or {}
        local index = 0
        return function()
          index = index + 1
          return entries[index]
        end
      end,
      stat = function(path)
        return fs_state.stats[path]
      end,
      lstat = function(path)
        return fs_state.stats[path]
      end,
      realpath = function(path)
        return fs_state.realpaths[path]
      end,
      remove = function(path)
        fs_state.removed[#fs_state.removed + 1] = path
        fs_state.exists[path] = nil
        return true
      end
    }
  end

  reset_package("dashboard.sources.record_store")
  local store = require("dashboard.sources.record_store")

  local payload = store.read()
  assert(payload.enable == "0", "record store should read enable from record section")
  assert(payload.record_time == "7", "record store should read record_time from record section")
  assert(payload.history_data_path == "/tmp/dashboard/history", "record store should read history path")

  local saved = store.write({
    enable = "1",
    record_time = "14",
    app_valid_time = "9",
    history_data_size = "256",
    history_data_path = "/tmp/dashboard/history"
  })
  assert(saved.enable == "1", "record store write should return saved enable")
  assert(cursor_state.values.record_time == "14", "record store write should persist record_time")
  assert(cursor_state.committed == true, "record store write should commit dashboard config")

  local clear_ok, clear_err = store.clear()
  assert(clear_ok == true, clear_err or "record store clear should succeed for safe path")
  assert(#fs_state.removed == 2, "record store clear should remove history files under safe path")

  fs_state.dirs["/tmp/dashboard/history"] = { "link-child" }
  fs_state.removed = {}
  cursor_state.values.history_data_path = "/tmp/dashboard/history"
  local nested_link_ok, nested_link_err = store.clear()
  assert(nested_link_ok == nil, "record store clear should reject nested symlink directory")
  assert(nested_link_err == "invalid_history_data_path", "record store clear should reject nested symlink directory")

  fs_state.dirs["/tmp/dashboard/history"] = { "day-1.json", "day-2.json" }
  cursor_state.values.history_data_path = "/tmp/dashboard/history.json"
  local file_ok, file_err = store.clear()
  assert(file_ok == nil, "record store clear should reject file path")
  assert(file_err == "invalid_history_data_path", "record store clear should report file path as invalid")

  cursor_state.values.history_data_path = "/tmp/dashboard/link-out"
  local link_ok, link_err = store.clear()
  assert(link_ok == nil, "record store clear should reject symlink escape path")
  assert(link_err == "invalid_history_data_path", "record store clear should reject symlink escape path")

  cursor_state.values.history_data_path = "/tmp/dashboard/broken-link"
  local broken_link_ok, broken_link_err = store.clear()
  assert(broken_link_ok == nil, "record store clear should reject broken symlink path")
  assert(broken_link_err == "invalid_history_data_path", "record store clear should reject broken symlink path")

  cursor_state.values.history_data_path = "/"
  local bad_ok, bad_err = store.clear()
  assert(bad_ok == nil, "record store clear should reject unsafe path")
  assert(bad_err == "invalid_history_data_path", "record store clear should report invalid history path")
end

do
  package.loaded["nixio.fs"] = {
    access = function(path)
      return path == "/tmp/dashboard/history.json"
        or path == "/tmp/dashboard/link-out"
        or path == "/tmp/dashboard/link"
    end,
    lstat = function(path)
      if path == "/tmp/dashboard/history.json" then
        return {
          type = "file"
        }
      end

      if path == "/tmp/dashboard/link-out" or path == "/tmp/dashboard/link" or path == "/tmp/dashboard/broken-link" then
        return {
          type = "link"
        }
      end

      return nil
    end,
    realpath = function(path)
      if path == "/tmp/dashboard/link-out" then
        return "/etc/passwd"
      end

      if path == "/tmp/dashboard/link" then
        return "/etc"
      end

      if path == "/tmp/dashboard/broken-link" then
        return nil
      end

      return path
    end,
    stat = function(path)
      if path == "/tmp/dashboard/history.json" then
        return {
          type = "file"
        }
      end

      if path == "/etc/passwd" then
        return {
          type = "file"
        }
      end

      return {
        type = "dir"
      }
    end
  }

  package.loaded["luci.dashboard.sources.record_store"] = {
    read = function()
      return {
        enable = "1",
        record_time = "7",
        app_valid_time = "5",
        history_data_size = "128",
        history_data_path = "/tmp/dashboard/history"
      }
    end,
    write = function(payload)
      _G.saved_record_payload = payload
      return payload
    end,
    clear = function()
      _G.record_history_cleared = true
      return true
    end
  }

  reset_package("dashboard.services.record")
  local record = require("dashboard.services.record")

  local valid_payload, valid_err = record.validate({
    enable = "1",
    record_time = "7",
    app_valid_time = "5",
    history_data_size = "128",
    history_data_path = "/tmp/dashboard/history"
  })
  assert(valid_payload ~= nil, "valid record payload should pass")
  assert(valid_err == nil, "valid record payload should not error")
  assert(valid_payload.history_data_size == "128", "valid payload should preserve history size")

  local invalid_file_payload, invalid_file_err, invalid_file_details = record.validate({
    enable = "1",
    record_time = "7",
    app_valid_time = "5",
    history_data_size = "128",
    history_data_path = "/tmp/dashboard/history.json"
  })
  assert(invalid_file_payload == nil, "existing file path should fail validation")
  assert(invalid_file_err == "invalid_history_data_path", "existing file path should report invalid_history_data_path")
  assert(invalid_file_details.field == "history_data_path", "existing file path should identify field")

  local invalid_link_payload, invalid_link_err, invalid_link_details = record.validate({
    enable = "1",
    record_time = "7",
    app_valid_time = "5",
    history_data_size = "128",
    history_data_path = "/tmp/dashboard/link-out"
  })
  assert(invalid_link_payload == nil, "symlink escape path should fail validation")
  assert(invalid_link_err == "invalid_history_data_path", "symlink escape path should report invalid_history_data_path")
  assert(invalid_link_details.field == "history_data_path", "symlink escape path should identify field")

  local invalid_parent_link_payload, invalid_parent_link_err, invalid_parent_link_details = record.validate({
    enable = "1",
    record_time = "7",
    app_valid_time = "5",
    history_data_size = "128",
    history_data_path = "/tmp/dashboard/link/records"
  })
  assert(invalid_parent_link_payload == nil, "path under symlinked parent should fail validation")
  assert(invalid_parent_link_err == "invalid_history_data_path", "path under symlinked parent should report invalid_history_data_path")
  assert(invalid_parent_link_details.field == "history_data_path", "path under symlinked parent should identify field")

  local invalid_broken_parent_payload, invalid_broken_parent_err, invalid_broken_parent_details = record.validate({
    enable = "1",
    record_time = "7",
    app_valid_time = "5",
    history_data_size = "128",
    history_data_path = "/tmp/dashboard/broken-link/records"
  })
  assert(invalid_broken_parent_payload == nil, "path under broken symlink parent should fail validation")
  assert(invalid_broken_parent_err == "invalid_history_data_path", "path under broken symlink parent should report invalid_history_data_path")
  assert(invalid_broken_parent_details.field == "history_data_path", "path under broken symlink parent should identify field")

  local invalid_payload, invalid_err, invalid_details = record.validate({
    enable = "1",
    record_time = "7",
    app_valid_time = "5",
    history_data_size = "2048",
    history_data_path = "/"
  })
  assert(invalid_payload == nil, "invalid history settings should fail")
  assert(invalid_err == "invalid_history_data_size", "invalid size should report invalid_history_data_size")
  assert(invalid_details.field == "history_data_size", "invalid size should identify field")

  local saved_payload, save_err = record.set({
    enable = "1",
    record_time = "7",
    app_valid_time = "5",
    history_data_size = "128",
    history_data_path = "/tmp/dashboard/history"
  })
  assert(saved_payload ~= nil, save_err or "record set should succeed")
  assert(_G.saved_record_payload.history_data_size == "128", "record set should pass normalized payload to store")

  local clear_ok, clear_err = record.clear_history()
  assert(clear_ok == true, clear_err or "record clear_history should succeed")
  assert(_G.record_history_cleared == true, "record clear_history should call store.clear")
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

  package.loaded["luci.dashboard.services.record"] = {
    get = function()
      return {
        enable = "1",
        record_time = "7",
        app_valid_time = "5",
        history_data_size = "128",
        history_data_path = "/tmp/dashboard/history"
      }
    end,
    set = function(payload)
      if payload.history_data_path == "/" then
        return nil, "invalid_history_data_path", {
          field = "history_data_path",
          value = "/"
        }
      end

      return payload
    end,
    clear_history = function()
      if form_state.name == "explode" then
        return nil, "runtime_error"
      end

      return true
    end
  }

  reset_package("dashboard.api.record")
  local api = require("dashboard.api.record")

  api.get()
  assert(response_body.ok == true, "record get API should return ok envelope")
  assert(response_body.data.history_data_size == "128", "record get API should return record payload")

  form_state = {
    enable = "1",
    record_time = "7",
    app_valid_time = "5",
    history_data_size = "128",
    history_data_path = "/tmp/dashboard/history"
  }
  api.post()
  assert(response_body.ok == true, "record post API should wrap successful save")
  assert(response_body.data.history_data_path == "/tmp/dashboard/history", "record post API should return saved payload")

  form_state.history_data_path = "/"
  api.post()
  assert(response_body.ok == false and response_body.error.code == "invalid_history_data_path", "record post API should reject invalid payload with specific code")

  form_state = { name = "clear_history" }
  api.action()
  assert(response_body.ok == true and response_body.data.cleared == true, "record action API should clear history")

  form_state = { name = "unknown" }
  api.action()
  assert(response_body.ok == false and response_body.error.code == "invalid_arg", "record action API should reject unknown actions")
end

do
  local request_uri = "/admin/dashboard/api/record/base"
  local request_method = "GET"
  local get_called = false
  local post_called = false
  local action_called = false

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
        return "csrf-token"
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
      return "sid", { token = "csrf-token" }
    end
  }

  package.loaded["luci.dashboard.api.overview"] = {
    get = function() end
  }

  package.loaded["luci.dashboard.api.network"] = {
    get_lan = function() end,
    post_lan = function() end,
    get_wan = function() end,
    post_wan = function() end,
    get_work_mode = function() end,
    post_work_mode = function() end
  }

  package.loaded["luci.dashboard.api.system"] = {
    get = function() end,
    post = function() end
  }

  package.loaded["luci.dashboard.api.settings"] = {
    get_dashboard = function() end,
    post_dashboard = function() end
  }

  package.loaded["luci.dashboard.api.users"] = {
    list = function() end,
    detail = function() end,
    remark = function() end
  }

  package.loaded["luci.dashboard.api.record"] = {
    get = function()
      get_called = true
    end,
    post = function()
      post_called = true
    end,
    action = function()
      action_called = true
    end
  }

  reset_package("luci.controller.dashboard")
  local controller = require("luci.controller.dashboard")

  controller.dashboard_dispatch()
  assert(get_called == true, "controller should dispatch record get route")

  request_method = "POST"
  controller.dashboard_dispatch()
  assert(post_called == true, "controller should dispatch record post route")

  request_uri = "/admin/dashboard/api/record/action"
  controller.dashboard_dispatch()
  assert(action_called == true, "controller should dispatch record action route")
end
