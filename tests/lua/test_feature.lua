local function reset_package(name)
  package.loaded[name] = nil
  package.preload[name] = nil
end

local function map_module(alias, target)
  package.preload[alias] = function()
    return require(target)
  end
end

map_module("luci.dashboard.sources.feature_store", "dashboard.sources.feature_store")
map_module("luci.dashboard.services.feature", "dashboard.services.feature")
map_module("luci.dashboard.api.feature", "dashboard.api.feature")

do
  package.loaded["luci.dashboard.sources.feature_store"] = {
    read_info = function()
      return {
        version = "2026.04.16",
        format = "v3.0",
        app_count = 12
      }
    end,
    read_classes = function()
      return {
        {
          id = 1,
          name = "Social",
          app_list = {
            "1001,WeChat,1",
            "1002,QQ,1"
          }
        }
      }
    end,
    read_status = function()
      return {
        state = "idle",
        updating = false,
        message = ""
      }
    end,
    import_bundle = function(tmp_path, filename)
      _G.imported_feature_bundle = {
        tmp_path = tmp_path,
        filename = filename
      }
      return {
        version = "2026.04.16",
        format = "v3.0",
        app_count = 12
      }, {
        {
          id = 1,
          name = "Social",
          app_list = {
            "1001,WeChat,1"
          }
        }
      }
    end
  }

  reset_package("dashboard.services.feature")
  local feature = require("dashboard.services.feature")

  local info = feature.get_info()
  assert(info.version == "2026.04.16", "feature info version mismatch")
  assert(info.app_count == 12, "feature info app count mismatch")

  local classes = feature.get_classes()
  assert(classes[1].name == "Social", "feature class name mismatch")
  assert(#classes[1].app_list == 2, "feature class app list mismatch")

  local status = feature.get_status()
  assert(status.state == "idle", "feature status state mismatch")
  assert(status.updating == false, "feature status updating mismatch")

  local imported, import_err = feature.import_bundle(
    "/tmp/upload-feature.tar.gz",
    "feature-pack.tar.gz",
    1024
  )
  assert(imported ~= nil, import_err or "import should succeed")
  assert(imported.version == "2026.04.16", "imported feature version mismatch")
  assert(_G.imported_feature_bundle.filename == "feature-pack.tar.gz", "bundle filename mismatch")

  local too_big, too_big_err = feature.import_bundle(
    "/tmp/upload-feature.tar.gz",
    "feature-pack.tar.gz",
    25 * 1024 * 1024
  )
  assert(too_big == nil and too_big_err == "bundle_too_large", "oversized bundle should be rejected")
end

do
  package.loaded["luci.dashboard.sources.feature_store"] = {
    read_info = function()
      return {
        version = "",
        format = "v3.0",
        app_count = "bad"
      }
    end,
    read_classes = function()
      return {
        social = {
          id = 1
        }
      }
    end,
    read_status = function()
      return {
        state = "idle",
        updating = false
      }
    end,
    set_status = function() end,
    write_bundle = function() end,
    import_bundle = function()
      return {
        version = "2026.04.16",
        format = "v3.0"
      }, {}
    end
  }

  reset_package("dashboard.services.feature")
  local feature = require("dashboard.services.feature")

  local invalid_info, invalid_info_err, invalid_info_details = feature.get_info()
  assert(invalid_info == nil, "invalid feature info should fail")
  assert(invalid_info_err == "invalid_feature_info", "invalid feature info should report invalid_feature_info")
  assert(invalid_info_details.field == "app_count", "invalid feature info should identify field")

  local invalid_classes, invalid_classes_err, invalid_classes_details = feature.get_classes()
  assert(invalid_classes == nil, "invalid feature classes should fail")
  assert(invalid_classes_err == "invalid_feature_classes", "invalid feature classes should report invalid_feature_classes")
  assert(invalid_classes_details.field == "classes", "invalid feature classes should identify field")

  local invalid_import, invalid_import_err = feature.import_bundle(
    "/tmp/upload-feature.tar.gz",
    "feature-pack.tar.gz",
    1024
  )
  assert(invalid_import == nil, "invalid imported metadata should fail")
  assert(invalid_import_err == "invalid_feature_info", "invalid imported metadata should report invalid_feature_info")
end

do
  local response_body
  local form_state = {}
  local file_handler = nil
  local removed_paths = {}
  local upload_filename = "feature-pack.tar.gz"

  package.loaded["luci.http"] = {
    formvalue = function(key)
      if key == "file" and file_handler then
        file_handler({ name = "file", file = upload_filename }, "feature-chunk", false)
        file_handler(nil, "", true)
      end
      return form_state[key]
    end,
    setfilehandler = function(handler)
      file_handler = handler
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

  local original_os_tmpname = os.tmpname
  local original_os_remove = os.remove

  os.tmpname = function()
    return "tests/fixtures/feature-upload.tmp"
  end

  os.remove = function(path)
    removed_paths[#removed_paths + 1] = path
    return true
  end

  package.loaded["luci.dashboard.services.feature"] = {
    get_info = function()
      return {
        version = "2026.04.16",
        format = "v3.0",
        app_count = 12
      }
    end,
    get_classes = function()
      return {
        {
          id = 1,
          name = "Social",
          app_list = {
            "1001,WeChat,1"
          }
        }
      }
    end,
    get_status = function()
      return {
        state = "idle",
        updating = false,
        message = ""
      }
    end,
    import_bundle = function(path, filename, size)
      if filename == "bad-pack.txt" then
        return nil, "invalid_bundle_extension"
      end

      return {
        version = "2026.04.16",
        format = "v3.0",
        app_count = 12
      }
    end
  }

  reset_package("dashboard.api.feature")
  local api = require("dashboard.api.feature")

  api.info()
  assert(response_body.ok == true, "feature info API should return ok envelope")
  assert(response_body.data.version == "2026.04.16", "feature info API should return feature info")

  api.classes()
  assert(response_body.ok == true, "feature classes API should return ok envelope")
  assert(response_body.data[1].name == "Social", "feature classes API should return classes")

  api.status()
  assert(response_body.ok == true, "feature status API should return ok envelope")
  assert(response_body.data.state == "idle", "feature status API should return status")

  file_handler = nil
  api.upload()
  assert(response_body.ok == true, "feature upload API should wrap successful upload")
  assert(response_body.data.app_count == 12, "feature upload API should return imported info")
  assert(removed_paths[1] == "tests/fixtures/feature-upload.tmp", "feature upload API should remove temporary upload")

  package.loaded["luci.dashboard.services.feature"].import_bundle = function()
    return nil, "invalid_bundle_extension"
  end
  upload_filename = "bad-pack.txt"
  file_handler = nil
  api.upload()
  assert(response_body.ok == false and response_body.error.code == "invalid_bundle_extension", "feature upload API should reject invalid bundle")

  package.loaded["luci.http"].formvalue = function(key)
    return form_state[key]
  end
  file_handler = nil
  api.upload()
  assert(response_body.ok == false and response_body.error.code == "invalid_arg", "feature upload API should reject missing upload")

  os.tmpname = original_os_tmpname
  os.remove = original_os_remove
end

do
  local request_uri = "/admin/dashboard/api/feature/info"
  local request_method = "GET"
  local info_called = false
  local classes_called = false
  local status_called = false
  local upload_called = false

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
    get = function() end,
    post = function() end,
    action = function() end
  }

  package.loaded["luci.dashboard.api.feature"] = {
    info = function()
      info_called = true
    end,
    classes = function()
      classes_called = true
    end,
    status = function()
      status_called = true
    end,
    upload = function()
      upload_called = true
    end
  }

  reset_package("luci.controller.dashboard")
  local controller = require("luci.controller.dashboard")

  controller.dashboard_dispatch()
  assert(info_called == true, "controller should dispatch feature info route")

  request_uri = "/admin/dashboard/api/feature/classes"
  controller.dashboard_dispatch()
  assert(classes_called == true, "controller should dispatch feature classes route")

  request_uri = "/admin/dashboard/api/feature/status"
  controller.dashboard_dispatch()
  assert(status_called == true, "controller should dispatch feature status route")

  request_method = "POST"
  request_uri = "/admin/dashboard/api/feature/upload"
  controller.dashboard_dispatch()
  assert(upload_called == true, "controller should dispatch feature upload route")
end
