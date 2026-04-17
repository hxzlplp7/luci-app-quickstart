local util = require("luci.util")

local M = {}

local function path_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function read_line(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end

  local value = f:read("*l")
  f:close()
  return value
end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end

  local value = f:read("*a")
  f:close()
  return value
end

local function exec_trim(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then
    return ""
  end

  local output = p:read("*a") or ""
  p:close()
  return output:gsub("%s+$", "")
end

function M.read()
  local board = util.ubus("system", "board", {}) or {}
  local release = read_all("/etc/openwrt_release") or ""
  local kernel = exec_trim("uname -r")
  local model = ""
  if type(board) == "table" and board.model then
    model = board.model
  end
  if model == "" then
    model = exec_trim("cat /tmp/sysinfo/model 2>/dev/null")
  end
  if model == "" then
    model = exec_trim("cat /proc/device-tree/model 2>/dev/null | tr -d '\\0'")
  end
  if model == "" then
    model = "Generic Device"
  end

  local uptime = tonumber((read_line("/proc/uptime") or "0"):match("^(%S+)")) or 0
  local load1 = tonumber((read_line("/proc/loadavg") or "0"):match("^(%S+)")) or 0
  local cpuinfo = read_all("/proc/cpuinfo") or ""
  local cpus = 0
  for _ in cpuinfo:gmatch("processor%s*:") do
    cpus = cpus + 1
  end
  if cpus == 0 then
    cpus = 1
  end

  local temp = 0
  for i = 0, 9 do
    local raw = tonumber(read_line("/sys/class/thermal/thermal_zone" .. i .. "/temp") or "")
    if raw then
      if raw > 1000 then
        temp = math.floor(raw / 1000)
        break
      end
      if raw > 0 then
        temp = raw
        break
      end
    end
  end

  local meminfo = read_all("/proc/meminfo") or ""
  local mem = {}
  for key, value in meminfo:gmatch("(%S+):%s+(%d+)") do
    mem[key] = tonumber(value)
  end
  local mem_total = mem.MemTotal or 1
  local mem_available = mem.MemAvailable or mem.MemFree or 0

  return {
    model = model,
    firmware = release:match("DISTRIB_DESCRIPTION='([^']*)'") or release:match('DISTRIB_DESCRIPTION="([^"]*)"') or "OpenWrt",
    kernel = kernel ~= "" and kernel or "unknown",
    uptime_raw = math.floor(uptime),
    cpuUsage = math.min(100, math.floor(load1 * 100 / cpus)),
    memUsage = math.floor((mem_total - mem_available) * 100 / mem_total),
    temp = temp,
    systime_raw = os.time(),
    hasSamba4 = path_exists("/usr/lib/lua/luci/controller/samba4.lua") or path_exists("/etc/config/samba4")
  }
end

return M
