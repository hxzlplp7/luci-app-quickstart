-- Dashboard NAS API
-- Handles: /nas/disk/status/, /u/nas/service/status/
-- Provides filtered disk information for the bundled dashboard frontend

local u = require "luci.dashboard.util"
local M = {}

local function human_size(bytes)
    local value = tonumber(bytes) or 0
    local units = { "B", "KB", "MB", "GB", "TB" }
    local unit = 1

    while value >= 1024 and unit < #units do
        value = value / 1024
        unit = unit + 1
    end

    if unit == 1 then
        return string.format("%d %s", value, units[unit])
    end

    return string.format("%.1f %s", value, units[unit])
end

local function parse_key_value_line(line)
    local result = {}

    for key, value in line:gmatch('([A-Z0-9_]+)="([^"]*)"') do
        result[key] = value
    end

    return result
end

local function load_df_map()
    local map = {}
    local df_out = u.exec("df -B1 -P 2>/dev/null")

    for line in df_out:gmatch("[^\n]+") do
        local dev, total, used, avail, pct, mount =
            line:match("^(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%S+)%s+(.+)$")
        if dev and mount and mount ~= "Mounted" then
            map[mount] = {
                total = tonumber(total) or 0,
                used = tonumber(used) or 0,
                available = tonumber(avail) or 0,
                usePercent = tonumber((pct or ""):match("(%d+)")) or 0,
                source = dev
            }
        end
    end

    return map
end

local function load_mounts()
    local mounts = {}
    local raw = u.read_file_all("/proc/mounts") or ""

    for line in raw:gmatch("[^\n]+") do
        local source, mountpoint, fstype, options =
            line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if source and mountpoint then
            mounts[#mounts + 1] = {
                source = source,
                mountpoint = mountpoint,
                fstype = fstype or "",
                options = options or ""
            }
        end
    end

    table.sort(mounts, function(a, b)
        return #a.mountpoint > #b.mountpoint
    end)

    return mounts
end

local function find_mount_for_path(path, mounts)
    if not path or path == "" then
        return nil
    end

    for _, mount in ipairs(mounts) do
        if path == mount.mountpoint or path:find(mount.mountpoint .. "/", 1, true) == 1 then
            return mount
        end
    end

    return nil
end

local function should_keep_partition(entry)
    local size = tonumber(entry.SIZE) or 0
    local mountpoint = entry.MOUNTPOINT or ""
    local fstype = entry.FSTYPE or ""

    if mountpoint == "/" or mountpoint == "/overlay" or mountpoint == "/opt" then
        return true
    end

    if mountpoint ~= "" then
        return not (
            mountpoint == "/rom" or
            mountpoint:find("/tmp", 1, true) == 1 or
            mountpoint:find("/proc", 1, true) == 1 or
            mountpoint:find("/sys", 1, true) == 1 or
            mountpoint:find("/dev", 1, true) == 1 or
            mountpoint:find("/run", 1, true) == 1
        )
    end

    if fstype ~= "" and fstype ~= "swap" then
        return size >= 268435456
    end

    return size >= 1073741824
end

local function build_partition(entry, df_map, mount_map, docker_mountpoint)
    local mountpoint = entry.MOUNTPOINT or ""
    local df = df_map[mountpoint]
    local mount = mount_map[mountpoint]
    local total = df and df.total or tonumber(entry.SIZE) or 0
    local used = df and df.used or 0
    local filesystem = entry.FSTYPE ~= "" and entry.FSTYPE or "No FileSystem"
    local is_read_only = false

    if entry.RO == "1" then
        is_read_only = true
    elseif mount and mount.options:match("(^|,)ro(,|$)") then
        is_read_only = true
    end

    return {
        name = entry.NAME,
        path = entry.PATH ~= "" and entry.PATH or ("/dev/" .. entry.NAME),
        mountPoint = mountpoint,
        total = human_size(total),
        used = human_size(used),
        usage = (df and df.usePercent) or 0,
        filesystem = filesystem,
        isReadOnly = is_read_only,
        isSystemRoot = mountpoint == "/" or mountpoint == "/overlay",
        uuid = entry.UUID or "",
        isDockerRoot = docker_mountpoint ~= "" and mountpoint == docker_mountpoint
    }
end

--- GET /nas/disk/status/
-- Returns disk/partition information in the structure expected by the frontend
function M.disk_status()
    local disks = {}
    local disk_map = {}
    local df_map = load_df_map()
    local mounts = load_mounts()
    local mount_map = {}
    local docker_mountpoint = ""
    local uci = require("luci.model.uci").cursor()
    local docker_root = nil
    local docker_mount = nil

    if u.file_exists("/etc/init.d/dockerd") or uci:get("dockerd", "globals") then
        docker_root = uci:get("dockerd", "globals", "data_root") or "/opt/docker"
        docker_mount = find_mount_for_path(docker_root, mounts)
    end

    if docker_mount then
        docker_mountpoint = docker_mount.mountpoint
    end

    for _, mount in ipairs(mounts) do
        mount_map[mount.mountpoint] = mount
    end

    local lsblk_out = u.exec("lsblk -P -b -o NAME,PATH,PKNAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,RO,UUID 2>/dev/null")
    for line in lsblk_out:gmatch("[^\n]+") do
        local entry = parse_key_value_line(line)
        local devtype = entry.TYPE

        if devtype == "disk" then
            local path = entry.PATH ~= "" and entry.PATH or ("/dev/" .. entry.NAME)
            local disk = {
                name = entry.NAME,
                path = path,
                size = human_size(entry.SIZE),
                venderModel = (entry.MODEL and entry.MODEL:gsub("^%s+", ""):gsub("%s+$", "")) ~= "" and entry.MODEL:gsub("^%s+", ""):gsub("%s+$", "") or entry.NAME,
                childrens = {},
                used = human_size(0),
                total = human_size(0),
                usage = 0,
                isSystemRoot = false,
                isDockerRoot = false,
                smartWarning = false
            }

            disks[#disks + 1] = disk
            disk_map[entry.NAME] = disk

            if entry.MOUNTPOINT ~= "" or entry.FSTYPE ~= "" then
                disk.childrens[#disk.childrens + 1] = build_partition(entry, df_map, mount_map, docker_mountpoint)
            end
        elseif devtype == "part" and disk_map[entry.PKNAME] and should_keep_partition(entry) then
            local disk = disk_map[entry.PKNAME]
            disk.childrens[#disk.childrens + 1] = build_partition(entry, df_map, mount_map, docker_mountpoint)
        end
    end

    for _, disk in ipairs(disks) do
        local used_total = 0
        local size_total = 0

        if #disk.childrens == 0 then
            disk.childrens[1] = {
                name = disk.name,
                path = disk.path,
                mountPoint = "",
                total = disk.size,
                used = human_size(0),
                usage = 0,
                filesystem = "No FileSystem",
                isReadOnly = false,
                isSystemRoot = false,
                uuid = ""
            }
        end

        table.sort(disk.childrens, function(a, b)
            if a.isSystemRoot ~= b.isSystemRoot then
                return a.isSystemRoot
            end

            if a.mountPoint ~= "" and b.mountPoint == "" then
                return true
            end

            if a.mountPoint == "" and b.mountPoint ~= "" then
                return false
            end

            return a.name < b.name
        end)

        for _, child in ipairs(disk.childrens) do
            local child_mount = child.mountPoint or ""
            local child_size = df_map[child_mount] and df_map[child_mount].total or 0
            local child_used = df_map[child_mount] and df_map[child_mount].used or 0

            if child_mount ~= "" then
                used_total = used_total + child_used
                size_total = size_total + child_size
            end

            if child.isSystemRoot then
                disk.isSystemRoot = true
            end

            if child.isDockerRoot then
                disk.isDockerRoot = true
            end
        end

        if size_total > 0 then
            disk.total = human_size(size_total)
            disk.used = human_size(used_total)
            disk.usage = math.floor((used_total * 100) / size_total)
        end
    end

    table.sort(disks, function(a, b)
        if a.isSystemRoot ~= b.isSystemRoot then
            return a.isSystemRoot
        end

        return a.name < b.name
    end)

    u.json_success({
        disks = disks
    })
end

--- GET /u/nas/service/status/
-- Returns installation and running status of common NAS services
function M.service_status()
    local function check_service(name)
        local installed = u.file_exists("/etc/init.d/" .. name)
        local running = false
        local enabled = false

        if installed then
            running = os.execute("/etc/init.d/" .. name .. " running >/dev/null 2>&1") == 0
            enabled = os.execute("/etc/init.d/" .. name .. " enabled >/dev/null 2>&1") == 0
        end

        return {
            installed = installed,
            running = running,
            enabled = enabled
        }
    end

    local samba = check_service("samba4")
    if not samba.installed then
        samba = check_service("samba")
    end

    u.json_success({
        samba = samba,
        webdav = check_service("webdav"),
        nfs = check_service("nfsd"),
        ftp = check_service("vsftpd"),
        transmission = check_service("transmission"),
        aria2 = check_service("aria2"),
        qbittorrent = check_service("qbittorrent"),
        docker = check_service("dockerd"),
        minidlna = check_service("minidlna")
    })
end

return M
