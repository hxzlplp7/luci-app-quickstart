package.path = table.concat({
  "luasrc/?.lua",
  "luasrc/?/init.lua",
  "luasrc/?/?.lua",
  "tests/lua/?.lua",
  package.path
}, ";")

local alias_prefixes = {
  ["luci.dashboard."] = "dashboard."
}

local loaders = package.loaders or package.searchers

package.seeall = package.seeall or function(module_table)
  if getmetatable(module_table) == nil then
    setmetatable(module_table, { __index = _G })
  end

  return module_table
end

local function set_package_env(chunk, env)
  if type(setfenv) == "function" then
    setfenv(chunk, env)
    return
  end

  if debug and type(debug.setupvalue) == "function" then
    debug.setupvalue(chunk, 1, env)
  end
end

local function expose_global_module(name, module_table)
  local scope = _G
  local segments = {}

  for segment in tostring(name):gmatch("[^%.]+") do
    segments[#segments + 1] = segment
  end

  for index = 1, #segments - 1 do
    local segment = segments[index]
    if type(scope[segment]) ~= "table" then
      scope[segment] = {}
    end
    scope = scope[segment]
  end

  if #segments > 0 then
    scope[segments[#segments]] = module_table
  end
end

local function load_dashboard_controller()
  local module_name = "luci.controller.dashboard"
  local module_table = package.loaded[module_name]

  if type(module_table) ~= "table" then
    module_table = {}
  end

  package.loaded[module_name] = module_table
  expose_global_module(module_name, module_table)

  setmetatable(module_table, { __index = _G })
  module_table.module = function(name, ...)
    package.loaded[name] = module_table
    expose_global_module(name, module_table)

    for index = 1, select("#", ...) do
      local option = select(index, ...)
      if type(option) == "function" then
        option(module_table)
      end
    end

    return module_table
  end

  local chunk, err = loadfile("luasrc/controller/dashboard.lua")
  if not chunk then
    error(err)
  end

  set_package_env(chunk, module_table)

  local ok, result = pcall(chunk)
  if not ok then
    error(result)
  end

  return package.loaded[module_name] or module_table
end

table.insert(loaders, 2, function(module_name)
  if module_name == "luci.controller.dashboard" then
    return load_dashboard_controller
  end

  for source_prefix, target_prefix in pairs(alias_prefixes) do
    if module_name:sub(1, #source_prefix) == source_prefix then
      local target_name = target_prefix .. module_name:sub(#source_prefix + 1)
      return function()
        local loaded = require(target_name)
        if loaded ~= nil and loaded ~= true then
          return loaded
        end

        local module_loaded = package.loaded[module_name]
        if module_loaded ~= nil and module_loaded ~= true then
          return module_loaded
        end

        local target_loaded = package.loaded[target_name]
        if target_loaded ~= nil and target_loaded ~= true then
          return target_loaded
        end

        return module_loaded or target_loaded or loaded
      end
    end
  end

  return "\n\tno local LuCI source alias for " .. module_name
end)

local test_file = assert(arg[1], "missing test file")
local ok, err = pcall(dofile, test_file)
if not ok then
  io.stderr:write(err .. "\n")
  os.exit(1)
end
io.stdout:write("PASS " .. test_file .. "\n")
