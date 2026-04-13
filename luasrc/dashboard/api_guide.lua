-- Dashboard Guide API
-- Handles: /guide/pppoe/, /guide/dns-config/, /guide/dhcp-client/, /guide/lan/,
--          /guide/client-mode/, /guide/gateway-router/, /guide/soft-source/,
--          /u/guide/ddns/, /guide/docker/*

local u = require "luci.dashboard.util"
local jsonc = require "luci.jsonc"

local M = {}

--- GET /guide/pppoe/
function M.pppoe_get()
    local uci = require("luci.model.uci").cursor()
    u.json_success({
        username = uci:get("network", "wan", "username") or "",
        password = uci:get("network", "wan", "password") or "",
        proto = uci:get("network", "wan", "proto") or "dhcp"
    })
end

--- POST /guide/pppoe/
function M.pppoe_post()
    local body = u.get_request_body()
    local uci = require("luci.model.uci").cursor()

    uci:set("network", "wan", "proto", "pppoe")
    if body.username then
        uci:set("network", "wan", "username", body.username)
    end
    if body.password then
        uci:set("network", "wan", "password", body.password)
    end

    uci:commit("network")
    os.execute("/etc/init.d/network reload >/dev/null 2>&1 &")

    u.json_success({ status = "ok" })
end

--- GET /guide/dns-config/
function M.dns_config_get()
    local uci = require("luci.model.uci").cursor()
    local dns_list = uci:get_list("network", "wan", "dns") or {}
    local proto = uci:get("network", "wan", "proto") or "dhcp"

    local dns_proto = "auto"
    if #dns_list > 0 then
        dns_proto = "manual"
    end

    u.json_success({
        dnsProto = dns_proto,
        dnsList = dns_list,
        interfaceName = "wan",
        proto = proto
    })
end

--- POST /guide/dns-config/
function M.dns_config_post()
    local body = u.get_request_body()
    local uci = require("luci.model.uci").cursor()

    if body.dnsProto == "manual" and body.manualDnsIp then
        if type(body.manualDnsIp) == "table" then
            uci:set_list("network", body.interfaceName or "wan", "dns", body.manualDnsIp)
        end
        -- Also set peerdns to 0 to prevent DHCP/PPPoE from overriding
        uci:set("network", body.interfaceName or "wan", "peerdns", "0")
    elseif body.dnsProto == "auto" then
        uci:delete("network", body.interfaceName or "wan", "dns")
        uci:set("network", body.interfaceName or "wan", "peerdns", "1")
    end

    uci:commit("network")
    os.execute("/etc/init.d/network reload >/dev/null 2>&1 &")

    u.json_success({ status = "ok" })
end

--- POST /guide/dhcp-client/
function M.dhcp_client_post()
    local body = u.get_request_body()
    local uci = require("luci.model.uci").cursor()

    uci:set("network", "wan", "proto", "dhcp")
    -- Clear PPPoE credentials if switching from PPPoE
    uci:delete("network", "wan", "username")
    uci:delete("network", "wan", "password")

    uci:commit("network")
    os.execute("/etc/init.d/network reload >/dev/null 2>&1 &")

    u.json_success({ status = "ok" })
end

--- GET /guide/client-mode/
function M.client_mode_get()
    local uci = require("luci.model.uci").cursor()
    u.json_success({
        mode = "router", -- default mode
        lan_ip = uci:get("network", "lan", "ipaddr") or "192.168.1.1",
        lan_netmask = uci:get("network", "lan", "netmask") or "255.255.255.0",
        lan_gateway = uci:get("network", "lan", "gateway") or "",
        wan_proto = uci:get("network", "wan", "proto") or "dhcp"
    })
end

--- POST /guide/client-mode/
-- Configure as bypass router (旁路由)
function M.client_mode_post()
    local body = u.get_request_body()
    local uci = require("luci.model.uci").cursor()

    if body.gateway then
        uci:set("network", "lan", "gateway", body.gateway)
    end
    if body.ipaddr then
        uci:set("network", "lan", "ipaddr", body.ipaddr)
    end
    if body.netmask then
        uci:set("network", "lan", "netmask", body.netmask)
    end
    if body.dns then
        if type(body.dns) == "table" then
            uci:set_list("network", "lan", "dns", body.dns)
        else
            uci:set("network", "lan", "dns", body.dns)
        end
    end

    uci:commit("network")
    os.execute("/etc/init.d/network reload >/dev/null 2>&1 &")

    u.json_success({ status = "ok" })
end

--- POST /guide/gateway-router/
-- Configure as main gateway router
function M.gateway_router_post()
    local body = u.get_request_body()
    local uci = require("luci.model.uci").cursor()

    -- Remove bypass router settings
    uci:delete("network", "lan", "gateway")

    if body.lan_ip then
        uci:set("network", "lan", "ipaddr", body.lan_ip)
    end

    uci:commit("network")
    os.execute("/etc/init.d/network reload >/dev/null 2>&1 &")

    u.json_success({ status = "ok" })
end

--- GET /guide/lan/
function M.lan_get()
    local uci = require("luci.model.uci").cursor()
    u.json_success({
        ipaddr = uci:get("network", "lan", "ipaddr") or "192.168.1.1",
        netmask = uci:get("network", "lan", "netmask") or "255.255.255.0"
    })
end

--- POST /guide/lan/
function M.lan_post()
    local body = u.get_request_body()
    local uci = require("luci.model.uci").cursor()

    if body.ipaddr then
        uci:set("network", "lan", "ipaddr", body.ipaddr)
    end
    if body.netmask then
        uci:set("network", "lan", "netmask", body.netmask)
    end

    uci:commit("network")
    os.execute("/etc/init.d/network reload >/dev/null 2>&1 &")

    u.json_success({ status = "ok" })
end

--- GET /guide/soft-source/
function M.soft_source_get()
    local content = u.read_file_all("/etc/opkg/distfeeds.conf") or ""
    local sources = {}
    for line in content:gmatch("[^\n]+") do
        if not line:match("^#") and line:match("%S") then
            local name, url = line:match("^%S+%s+(%S+)%s+(%S+)")
            if name and url then
                sources[#sources + 1] = { name = name, url = url }
            end
        end
    end

    u.json_success({
        sources = sources,
        content = content
    })
end

--- POST /guide/soft-source/
function M.soft_source_post()
    local body = u.get_request_body()

    if body.content then
        local f = io.open("/etc/opkg/distfeeds.conf", "w")
        if f then
            f:write(body.content)
            f:close()
        end
    end

    u.json_success({ status = "ok" })
end

--- GET /guide/soft-source/list/
function M.soft_source_list()
    u.json_success({
        list = {
            {
                name = "Official OpenWrt",
                url = "https://downloads.openwrt.org"
            },
            {
                name = "USTC Mirror",
                url = "https://mirrors.ustc.edu.cn/openwrt"
            },
            {
                name = "Tsinghua Mirror",
                url = "https://mirrors.tuna.tsinghua.edu.cn/openwrt"
            },
            {
                name = "Aliyun Mirror",
                url = "https://mirrors.aliyun.com/openwrt"
            }
        }
    })
end

--- GET /u/guide/ddns/
function M.ddns_get()
    local uci = require("luci.model.uci").cursor()
    local services = {}

    if u.file_exists("/etc/config/ddns") then
        uci:foreach("ddns", "service", function(s)
            services[#services + 1] = {
                name = s[".name"],
                enabled = (s.enabled == "1"),
                service_name = s.service_name or "",
                domain = s.domain or "",
                username = s.username or "",
                lookup_host = s.lookup_host or ""
            }
        end)
    end

    u.json_success({ services = services })
end

--- POST /u/guide/ddns/
function M.ddns_post()
    local body = u.get_request_body()
    local uci = require("luci.model.uci").cursor()

    if not u.file_exists("/etc/config/ddns") then
        u.json_error(0, "ddns not installed")
        return
    end

    if body.name then
        local section = body.name
        -- Create or update DDNS service section
        if not uci:get("ddns", section) then
            uci:set("ddns", section, "service")
        end

        if body.enabled ~= nil then
            uci:set("ddns", section, "enabled", body.enabled and "1" or "0")
        end
        if body.service_name then
            uci:set("ddns", section, "service_name", body.service_name)
        end
        if body.domain then
            uci:set("ddns", section, "domain", body.domain)
        end
        if body.username then
            uci:set("ddns", section, "username", body.username)
        end
        if body.password then
            uci:set("ddns", section, "password", body.password)
        end

        uci:commit("ddns")
        os.execute("/etc/init.d/ddns restart >/dev/null 2>&1 &")
    end

    u.json_success({ status = "ok" })
end

-- ========== Docker Management APIs ==========

--- GET /guide/docker/status/
function M.docker_status()
    local result = {
        installed = false,
        running = false,
        status = "not installed",
        dataDir = "/opt/docker",
        dataDevice = "",
        dataUsage = "",
        containers = 0,
        runningCount = 0,
        images = 0
    }

    if u.file_exists("/etc/init.d/dockerd") then
        result.installed = true
        result.status = "stopped"

        -- Check if running
        if os.execute("pgrep -x dockerd >/dev/null 2>&1") == 0 then
            result.running = true
            result.status = "running"
            
            -- Get detailed stats if docker command is available
            if u.file_exists("/usr/bin/docker") then
                local running = u.exec("docker ps -q | wc -l")
                local total = u.exec("docker ps -aq | wc -l")
                local images = u.exec("docker images -q | wc -l")
                
                result.runningCount = tonumber(running) or 0
                result.containers = tonumber(total) or 0
                result.images = tonumber(images) or 0
            end
        end

        -- Get data directory
        local uci = require("luci.model.uci").cursor()
        if uci:get("dockerd", "globals") then
            result.dataDir = uci:get("dockerd", "globals", "data_root") or "/opt/docker"
        end

        -- Check disk usage of data dir
        if u.file_exists(result.dataDir) then
            local df_out = u.exec("df -h " .. result.dataDir .. " | tail -1")
            local dev, size, used, avail, pct, mount =
                df_out:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if dev then
                result.dataDevice = dev
                result.dataUsage = used .. " / " .. size .. " (" .. pct .. ")"
            end
        end
    end

    u.json_success(result)
end

--- GET /guide/docker/partition/list/
-- Returns available partitions for Docker data migration
function M.docker_partition_list()
    local partitions = {}

    -- Use lsblk to get block devices
    local lsblk_out = u.exec("lsblk -b -n -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE 2>/dev/null")
    for line in lsblk_out:gmatch("[^\n]+") do
        local name, size, fstype, mountpoint, devtype =
            line:match("^%s*(%S+)%s+(%S+)%s+(%S*)%s*(%S*)%s*(%S*)")
        if name and (devtype == "part" or devtype == "disk") then
            local size_num = tonumber(size) or 0
            -- Only show partitions > 1GB with a valid filesystem
            if size_num > 1073741824 and fstype and fstype ~= "" then
                local size_gb = string.format("%.1f GB", size_num / 1073741824)
                partitions[#partitions + 1] = {
                    name = name,
                    path = "/dev/" .. name,
                    size = size_num,
                    sizeStr = size_gb,
                    fstype = fstype,
                    mountpoint = mountpoint or ""
                }
            end
        end
    end

    u.json_success({ partitions = partitions })
end

--- POST /guide/docker/transfer/
-- Migrate Docker data directory to a new partition
function M.docker_transfer()
    local body = u.get_request_body()
    local target = body.target -- target mount point or device path

    if not target or target == "" then
        u.json_error(0, "Target partition not specified")
        return
    end

    local uci = require("luci.model.uci").cursor()
    local current_dir = "/opt/docker"
    if uci:get("dockerd", "globals") then
        current_dir = uci:get("dockerd", "globals", "data_root") or "/opt/docker"
    end

    -- Determine mount point: if target is a device, mount it first
    local mount_point = target
    if target:match("^/dev/") then
        mount_point = "/mnt/" .. target:match("/dev/(%S+)")
        os.execute("mkdir -p " .. mount_point)
        -- Check if already mounted
        local mounts = u.read_file_all("/proc/mounts") or ""
        if not mounts:match(target) then
            local ret = os.execute("mount " .. target .. " " .. mount_point .. " 2>/dev/null")
            if ret ~= 0 then
                u.json_error(0, "Failed to mount " .. target)
                return
            end
        end
    end

    local new_docker_dir = mount_point .. "/docker"

    -- Execute migration in background script
    local script = string.format([[
#!/bin/sh
# Docker data migration script
set -e
NEW_DIR="%s"
OLD_DIR="%s"
MOUNT="%s"

mkdir -p "$NEW_DIR"

# Stop Docker
/etc/init.d/dockerd stop 2>/dev/null || true
sleep 2

# Copy data
if [ -d "$OLD_DIR" ] && [ "$(ls -A $OLD_DIR 2>/dev/null)" ]; then
    cp -a "$OLD_DIR/." "$NEW_DIR/" 2>/dev/null || rsync -avz "$OLD_DIR/" "$NEW_DIR/"
fi

# Update Docker config
uci set dockerd.globals.data_root="$NEW_DIR"
uci commit dockerd

# Ensure auto-mount
if echo "$MOUNT" | grep -q "^/dev/"; then
    # Add fstab entry if not exists
    FSTAB_DEV="$MOUNT"
    if ! grep -q "$FSTAB_DEV" /etc/config/fstab 2>/dev/null; then
        block detect | uci import fstab 2>/dev/null || true
    fi
fi

# Restart Docker
/etc/init.d/dockerd start 2>/dev/null || true
]], new_docker_dir, current_dir, target)

    local f = io.open("/tmp/docker_migrate.sh", "w")
    if f then
        f:write(script)
        f:close()
        os.execute("chmod +x /tmp/docker_migrate.sh")
        os.execute("/tmp/docker_migrate.sh >/tmp/docker_migrate.log 2>&1 &")
    end

    u.json_success({
        status = "migrating",
        message = "Docker data migration started in background",
        newDir = new_docker_dir
    })
end

--- POST /guide/docker/switch/
-- Enable or disable Docker service
function M.docker_switch()
    local body = u.get_request_body()

    if not u.file_exists("/etc/init.d/dockerd") then
        u.json_error(0, "Docker not installed")
        return
    end

    if body.enable then
        os.execute("/etc/init.d/dockerd enable >/dev/null 2>&1")
        os.execute("/etc/init.d/dockerd start >/dev/null 2>&1 &")
    else
        os.execute("/etc/init.d/dockerd stop >/dev/null 2>&1")
        os.execute("/etc/init.d/dockerd disable >/dev/null 2>&1")
    end

    u.json_success({ status = "ok" })
end

-- ========== Download Service APIs (graceful degradation) ==========

--- GET /guide/download-service/status/
function M.download_service_status()
    u.json_success({
        aria2 = u.file_exists("/etc/init.d/aria2"),
        qbittorrent = u.file_exists("/etc/init.d/qbittorrent"),
        transmission = u.file_exists("/etc/init.d/transmission")
    })
end

return M
