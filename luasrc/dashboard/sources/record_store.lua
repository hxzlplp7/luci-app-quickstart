local uci = require("luci.model.uci")
local fs = require("nixio.fs")

local M = {}
local SECTION = "record"
local DEFAULTS = {
  enable = "0",
  record_time = "7",
  app_valid_time = "5",
  history_data_size = "128",
  history_data_path = "/tmp/dashboard/history"
}

local function get_cursor()
  return uci.cursor()
end

local function read_option(cursor, option)
  return tostring(cursor:get("dashboard", SECTION, option) or DEFAULTS[option] or "")
end

local function is_safe_history_path(path)
  local value = tostring(path or "")
  return value ~= ""
    and value ~= "/"
    and value:sub(-1) ~= "/"
    and value:match("^/tmp/dashboard/[%w%._%-/]+$") ~= nil
    and not value:find("//", 1, true)
    and not value:find("%.%.")
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

local function stat_type(path)
  if type(fs.stat) ~= "function" then
    return nil
  end

  local stat = fs.stat(path)
  if type(stat) == "table" then
    return stat.type
  end

  return stat
end

local function clear_tree(path)
  for entry in fs.dir(path) do
    if entry ~= "." and entry ~= ".." then
      local child = path .. "/" .. entry
      local resolved_child = resolve_path(child)
      if resolved_child ~= child or not is_safe_history_path(resolved_child) then
        return nil, "invalid_history_data_path"
      end

      local child_type = stat_type(child)

      if child_type == "dir" then
        local ok, err = clear_tree(resolved_child)
        if not ok then
          return nil, err
        end

        local removed = type(fs.rmdir) == "function" and fs.rmdir(child) or fs.remove(child)
        if removed == false or removed == nil then
          return nil, "clear_failed"
        end
      else
        local removed = fs.remove(child)
        if removed == false or removed == nil then
          return nil, "clear_failed"
        end
      end
    end
  end

  return true
end

function M.read()
  local cursor = get_cursor()

  return {
    enable = read_option(cursor, "enable"),
    record_time = read_option(cursor, "record_time"),
    app_valid_time = read_option(cursor, "app_valid_time"),
    history_data_size = read_option(cursor, "history_data_size"),
    history_data_path = read_option(cursor, "history_data_path")
  }
end

function M.write(payload)
  local cursor = get_cursor()
  local source = type(payload) == "table" and payload or {}

  for _, option in ipairs({ "enable", "record_time", "app_valid_time", "history_data_size", "history_data_path" }) do
    if source[option] ~= nil then
      cursor:set("dashboard", SECTION, option, tostring(source[option]))
    end
  end

  cursor:save("dashboard")
  cursor:commit("dashboard")

  return M.read()
end

function M.clear()
  local current = M.read()
  local history_path = current.history_data_path
  local resolved_path = history_path

  if not is_safe_history_path(history_path) then
    return nil, "invalid_history_data_path"
  end

  if not path_exists(history_path) then
    return true
  end

  resolved_path = resolve_path(history_path)
  if resolved_path == nil or resolved_path ~= history_path or not is_safe_history_path(resolved_path) then
    return nil, "invalid_history_data_path"
  end

  if stat_type(resolved_path) and stat_type(resolved_path) ~= "dir" then
    return nil, "invalid_history_data_path"
  end

  return clear_tree(resolved_path)
end

return M
