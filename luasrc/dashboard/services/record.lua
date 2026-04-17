local store = require("luci.dashboard.sources.record_store")
local fs = require("nixio.fs")

local M = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function invalid(code, field, value)
  return nil, code, {
    field = field,
    value = value
  }
end

local function is_safe_history_path(path)
  local value = trim(path)
  return value ~= ""
    and value ~= "/"
    and value:sub(-1) ~= "/"
    and value:match("^/tmp/dashboard/[%w%._%-/]+$") ~= nil
    and not value:find("//", 1, true)
    and not value:find("%.%.")
end

local function normalize_integer(value)
  local text = trim(value)
  if text == "" or text:match("^%d+$") == nil then
    return nil
  end

  return text, tonumber(text)
end

local function resolve_path(path)
  if type(fs.realpath) == "function" then
    return fs.realpath(path)
  end

  return path
end

local function path_exists(path)
  if type(fs.lstat) == "function" then
    return fs.lstat(path) ~= nil
  end

  return type(fs.access) == "function" and fs.access(path) or false
end

local function parent_path(path)
  local parent = trim(path):match("^(.*)/[^/]+$")
  if not parent or parent == "" then
    return "/"
  end

  return parent
end

local function existing_path_is_invalid_dir(path)
  local current = trim(path)

  while current ~= "" do
    if path_exists(current) then
      local resolved = resolve_path(current)
      if resolved == nil or resolved ~= current or not is_safe_history_path(resolved) then
        return true
      end

      if current ~= path or type(fs.stat) ~= "function" then
        return false
      end

      local stat = fs.stat(resolved)
      local kind = type(stat) == "table" and stat.type or stat
      return kind ~= nil and kind ~= "dir"
    end

    if current == "/" then
      break
    end

    current = parent_path(current)
  end

  return false
end

function M.validate(payload)
  local source = type(payload) == "table" and payload or {}
  local enable = trim(source.enable)
  local record_time_text, record_time = normalize_integer(source.record_time)
  local app_valid_time_text, app_valid_time = normalize_integer(source.app_valid_time)
  local history_data_size_text, history_data_size = normalize_integer(source.history_data_size)
  local history_data_path = trim(source.history_data_path)

  if enable ~= "0" and enable ~= "1" then
    return invalid("invalid_enable", "enable", enable)
  end

  if not record_time or record_time < 1 or record_time > 30 then
    return invalid("invalid_record_time", "record_time", source.record_time)
  end

  if not app_valid_time or app_valid_time < 1 or app_valid_time > 30 then
    return invalid("invalid_app_valid_time", "app_valid_time", source.app_valid_time)
  end

  if not history_data_size or history_data_size < 1 or history_data_size > 1024 then
    return invalid("invalid_history_data_size", "history_data_size", source.history_data_size)
  end

  if not is_safe_history_path(history_data_path) then
    return invalid("invalid_history_data_path", "history_data_path", source.history_data_path)
  end

  if existing_path_is_invalid_dir(history_data_path) then
    return invalid("invalid_history_data_path", "history_data_path", source.history_data_path)
  end

  return {
    enable = enable,
    record_time = record_time_text,
    app_valid_time = app_valid_time_text,
    history_data_size = history_data_size_text,
    history_data_path = history_data_path
  }
end

function M.get()
  return store.read()
end

function M.set(payload)
  local normalized, err, details = M.validate(payload)
  if not normalized then
    return nil, err, details
  end

  return store.write(normalized)
end

function M.clear_history()
  return store.clear()
end

return M
