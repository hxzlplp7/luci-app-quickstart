local jsonc = require("luci.jsonc")
local fs = require("nixio.fs")

local M = {}

local FEATURE_ROOT = "/etc/dashboard/feature"
local INFO_FILE = FEATURE_ROOT .. "/feature.info.json"
local CLASSES_FILE = FEATURE_ROOT .. "/feature.classes.json"
local STATUS_FILE = FEATURE_ROOT .. "/feature.status.json"

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local content = file:read("*a")
  file:close()
  return content
end

local function read_json(path, fallback)
  local content = read_file(path)
  if not content or content == "" then
    return fallback
  end

  return jsonc.parse(content) or fallback
end

local function write_json(path, payload)
  local file = assert(io.open(path, "w"))
  file:write(jsonc.stringify(payload))
  file:close()
end

local function ensure_root()
  fs.mkdirr(FEATURE_ROOT)
end

local function normalize_entry(entry)
  return tostring(entry or ""):gsub("\r", ""):gsub("^%./", "")
end

local function is_safe_entry(entry)
  return entry ~= ""
    and entry:sub(1, 1) ~= "/"
    and not entry:find("\\", 1, true)
    and not entry:find("%.%.")
end

local function run_read_command(command)
  local handle = io.popen(command)
  if not handle then
    return nil, "command_failed"
  end

  local output = handle:read("*a") or ""
  local ok = handle:close()
  if ok == nil or ok == false then
    return nil, "command_failed"
  end

  return output
end

local function list_archive_entries(archive_path)
  local output, err = run_read_command("tar -tzf " .. shell_quote(archive_path) .. " 2>/dev/null")
  if not output then
    return nil, err
  end

  local entries = {}
  for line in output:gmatch("[^\n]+") do
    local original_entry = tostring(line or ""):gsub("\r", "")
    local entry = normalize_entry(original_entry)
    if not is_safe_entry(entry) then
      return nil, "invalid_bundle_entries", {
        field = "entry",
        value = entry
      }
    end

    entries[entry] = original_entry
  end

  if not entries["feature.info.json"] or not entries["feature.classes.json"] then
    return nil, "bundle_metadata_missing"
  end

  return entries
end

local function extract_member(archive_path, member_name)
  return run_read_command(
    "tar -xOf "
      .. shell_quote(archive_path)
      .. " "
      .. shell_quote(member_name)
      .. " 2>/dev/null"
  )
end

local function default_status()
  return {
    state = "idle",
    updating = false,
    message = "",
    last_error = "",
    updated_at = ""
  }
end

local function write_status(status)
  ensure_root()
  write_json(STATUS_FILE, status)
end

function M.set_status(status)
  write_status(status)
end

function M.read_info()
  return read_json(INFO_FILE, {
    version = "",
    format = "",
    app_count = 0
  })
end

function M.read_classes()
  return read_json(CLASSES_FILE, {})
end

function M.read_status()
  return read_json(STATUS_FILE, default_status())
end

function M.import_bundle(tmp_path, filename)
  local archive_path = tostring(tmp_path or "")
  local bundle_name = tostring(filename or "")

  ensure_root()
  write_status({
    state = "importing",
    updating = true,
    message = bundle_name,
    last_error = "",
    updated_at = ""
  })

  local entries, entries_err, entries_details = list_archive_entries(archive_path)
  if not entries then
    write_status({
      state = "error",
      updating = false,
      message = bundle_name,
      last_error = entries_err,
      updated_at = ""
    })
    return nil, entries_err, entries_details
  end

  local info_payload, info_err = extract_member(archive_path, entries["feature.info.json"])
  if not info_payload then
    write_status({
      state = "error",
      updating = false,
      message = bundle_name,
      last_error = info_err,
      updated_at = ""
    })
    return nil, info_err
  end

  local classes_payload, classes_err = extract_member(archive_path, entries["feature.classes.json"])
  if not classes_payload then
    write_status({
      state = "error",
      updating = false,
      message = bundle_name,
      last_error = classes_err,
      updated_at = ""
    })
    return nil, classes_err
  end

  local info = jsonc.parse(info_payload)
  local classes = jsonc.parse(classes_payload)
  if type(info) ~= "table" or type(classes) ~= "table" then
    write_status({
      state = "error",
      updating = false,
      message = bundle_name,
      last_error = "invalid_bundle_metadata",
      updated_at = ""
    })
    return nil, "invalid_bundle_metadata"
  end

  return info, classes
end

function M.write_bundle(info, classes, filename)
  local bundle_name = tostring(filename or "")

  ensure_root()
  write_json(INFO_FILE, info)
  write_json(CLASSES_FILE, classes)
  write_status({
    state = "ready",
    updating = false,
    message = bundle_name,
    last_error = "",
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  })

  return true
end

return M
