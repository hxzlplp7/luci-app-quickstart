-- Dashboard System API
-- Handles: /system/status/, /u/system/version/, /system/reboot/

local u = require "luci.dashboard.util"

local M = {}

--- GET /system/status/
-- Returns CPU usage, temperature, memory, uptime, localtime
function M.status()
    local result = {}

    -- Uptime (seconds)
    local uptime_str = u.read_file("/proc/uptime") or "0"
    result.uptime = math.floor(tonumber(uptime_str:match("^(%S+)")) or 0)

    -- Local time
    result.localtime = os.date("%Y-%m-%d %H:%M:%S")

    -- CPU usage from load average
    local loadavg = u.read_file("/proc/loadavg") or "0"
    local load1 = tonumber(loadavg:match("^(%S+)")) or 0

    -- Count CPU cores
    local cpus = 0
    local cpuinfo = u.read_file_all("/proc/cpuinfo") or ""
    for _ in cpuinfo:gmatch("processor%s*:") do
        cpus = cpus + 1
    end
    if cpus == 0 then cpus = 1 end

    result.cpuUsage = math.min(100, math.floor(load1 * 100 / cpus))

    -- CPU temperature
    result.cpuTemperature = 0
    -- Try common thermal zone paths
    for i = 0, 5 do
        local temp_str = u.read_file("/sys/class/thermal/thermal_zone" .. i .. "/temp")
        if temp_str then
            local temp = tonumber(temp_str) or 0
            if temp > 0 then
                result.cpuTemperature = math.floor(temp / 1000)
                break
            end
        end
    end

    -- Memory info
    local meminfo = u.read_file_all("/proc/meminfo") or ""
    local mem = {}
    for key, val in meminfo:gmatch("(%S+):%s+(%d+)") do
        mem[key] = tonumber(val)
    end

    local mem_total = mem.MemTotal or 1
    local mem_available = mem.MemAvailable or mem.MemFree or 0
    result.memTotal = mem_total
    result.memAvailable = mem_available
    result.memAvailablePercentage = math.floor(mem_available * 100 / mem_total)

    -- Connection tracking
    local conncount_str = u.read_file("/proc/sys/net/netfilter/nf_conntrack_count")
    local connmax_str = u.read_file("/proc/sys/net/netfilter/nf_conntrack_max")
    result.connCount = tonumber(conncount_str) or 0
    result.connMax = tonumber(connmax_str) or 0

    u.json_success(result)
end

--- GET /u/system/version/
-- Returns firmware version, device model, kernel version
function M.version()
    local result = {}

    -- Device model
    result.model = u.read_file("/tmp/sysinfo/model") or "OpenWrt"

    -- Firmware version from /etc/openwrt_release
    local release = u.read_file_all("/etc/openwrt_release") or ""
    for key, val in release:gmatch("(%S+)='([^']*)'") do
        if key == "DISTRIB_DESCRIPTION" then
            result.firmwareVersion = val
        elseif key == "DISTRIB_TARGET" then
            result.target = val
        elseif key == "DISTRIB_ARCH" then
            result.arch = val
        end
    end
    if not result.firmwareVersion then
        -- Fallback: try without quotes
        for key, val in release:gmatch('(%S+)="([^"]*)"') do
            if key == "DISTRIB_DESCRIPTION" then
                result.firmwareVersion = val
            end
        end
    end
    result.firmwareVersion = result.firmwareVersion or "OpenWrt"

    -- Kernel version
    result.kernelVersion = u.exec("uname -r"):gsub("%s+$", "")

    u.json_success(result)
end

--- POST /system/reboot/
-- Triggers system reboot
function M.reboot()
    u.json_success({ rebooting = true })
    -- Schedule reboot after response is sent
    os.execute("sleep 1 && reboot &")
end

return M
