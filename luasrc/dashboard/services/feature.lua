local store = require("luci.dashboard.sources.feature_store")

local M = {}
local MAX_BUNDLE_SIZE = 20 * 1024 * 1024

local function invalid(code, field, value)
  return nil, code, {
    field = field,
    value = value
  }
end

local function validate_info(info)
  if type(info) ~= "table" then
    return invalid("invalid_feature_info", "info", info)
  end

  local version = tostring(info.version or "")
  local format = tostring(info.format or "")
  local app_count = tonumber(info.app_count)

  if version == "" then
    return invalid("invalid_feature_info", "version", info.version)
  end

  if format == "" then
    return invalid("invalid_feature_info", "format", info.format)
  end

  if not app_count or app_count < 0 or app_count ~= math.floor(app_count) then
    return invalid("invalid_feature_info", "app_count", info.app_count)
  end

  return {
    version = version,
    format = format,
    app_count = app_count
  }
end

local function validate_classes(classes)
  if type(classes) ~= "table" then
    return invalid("invalid_feature_classes", "classes", classes)
  end

  local count = 0
  for key in pairs(classes) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return invalid("invalid_feature_classes", "classes", classes)
    end

    count = count + 1
  end

  for index = 1, count do
    if classes[index] == nil then
      return invalid("invalid_feature_classes", "classes", classes)
    end
  end

  local normalized = {}

  for index, item in ipairs(classes) do
    if type(item) ~= "table" then
      return invalid("invalid_feature_classes", string.format("classes[%d]", index), item)
    end

    local name = tostring(item.name or "")
    if name == "" then
      return invalid("invalid_feature_classes", string.format("classes[%d].name", index), item.name)
    end

    if type(item.app_list) ~= "table" then
      return invalid("invalid_feature_classes", string.format("classes[%d].app_list", index), item.app_list)
    end

    local normalized_item = {
      id = item.id,
      name = name,
      app_list = {}
    }

    for app_index, app in ipairs(item.app_list) do
      local value = tostring(app or "")
      if value == "" then
        return invalid("invalid_feature_classes", string.format("classes[%d].app_list[%d]", index, app_index), app)
      end

      normalized_item.app_list[#normalized_item.app_list + 1] = value
    end

    normalized[#normalized + 1] = normalized_item
  end

  return normalized
end

local function normalize_status(status)
  local source = type(status) == "table" and status or {}

  return {
    state = tostring(source.state or "idle"),
    updating = source.updating == true,
    message = tostring(source.message or ""),
    last_error = tostring(source.last_error or ""),
    updated_at = tostring(source.updated_at or "")
  }
end

function M.get_info()
  return validate_info(store.read_info())
end

function M.get_classes()
  return validate_classes(store.read_classes())
end

function M.get_status()
  return normalize_status(store.read_status())
end

function M.import_bundle(tmp_path, filename, size)
  local bundle_size = tonumber(size or 0) or 0
  local bundle_name = tostring(filename or "")
  local archive_path = tostring(tmp_path or "")

  if bundle_size > MAX_BUNDLE_SIZE then
    return nil, "bundle_too_large", {
      field = "size",
      value = bundle_size
    }
  end

  if bundle_name == "" or bundle_name:match("%.tar%.gz$") == nil then
    return nil, "invalid_bundle_extension", {
      field = "filename",
      value = bundle_name
    }
  end

  if archive_path == "" then
    return nil, "invalid_bundle_path", {
      field = "tmp_path",
      value = archive_path
    }
  end

  local info, classes, err, details = store.import_bundle(archive_path, bundle_name)
  if not info then
    return nil, classes or err, err or details
  end

  local normalized_info, info_err, info_details = validate_info(info)
  if not normalized_info then
    store.set_status({
      state = "error",
      updating = false,
      message = bundle_name,
      last_error = info_err,
      updated_at = ""
    })
    return nil, info_err, info_details
  end

  local normalized_classes, classes_err, classes_details = validate_classes(classes)
  if not normalized_classes then
    store.set_status({
      state = "error",
      updating = false,
      message = bundle_name,
      last_error = classes_err,
      updated_at = ""
    })
    return nil, classes_err, classes_details
  end

  store.write_bundle(normalized_info, normalized_classes, bundle_name)
  return normalized_info
end

return M
