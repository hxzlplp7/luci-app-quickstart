-- Dashboard Network API
-- Handles: /u/network/status/, /u/network/statistics/, /network/device/list/,
--          /network/port/list/, /network/interface/config/, /network/checkPublicNet/

local u = require "luci.dashboard.util"
local util = require "luci.util"
local jsonc = require "luci.jsonc"

local M = {}

local TRAFFIC_STATE_FILE = "/tmp/dashboard_traffic.json"
local TRAFFIC_SLOTS = 10

local function split_words(value)
    local result = {}

    if type(value) == "table" then
        for _, item in ipairs(value) do
            if item and item ~= "" then
                result[#result + 1] = tostring(item)
            end
        end
    elseif type(value) == "string" then
        for item in value:gmatch("%S+") do
            result[#result + 1] = item
        end
    end

    return result
end

local function add_unique(list, seen, value)
    if value and value ~= "" and not seen[value] then
        seen[value] = true
        list[#list + 1] = value
    end
end

local function read_number(path)
    return tonumber((u.read_file(path) or ""):match("(%d+)")) or 0
end

local function load_json_file(path)
    local raw = u.read_file_all(path)
    if not raw or raw == "" then
        return {}
    end

    return jsonc.parse(raw) or {}
end

local function save_json_file(path, data)
    local f = io.open(path, "w")
    if not f then
        return
    end

    f:write(jsonc.stringify(data or {}))
    f:close()
end

local function get_interface_dump_entries()
    local dump = util.ubus("network.interface", "dump", {}) or {}
    return dump.interface or dump.interfaces or {}
end

local function entry_has_default_route(entry)
    for _, route in ipairs(entry.route or {}) do
        local target = route.target
        if target == "0.0.0.0" or target == "::/0" then
            return true
        end
    end

    return false
end

local function entry_has_address(entry)
    return (entry["ipv4-address"] and #entry["ipv4-address"] > 0) or
        (entry["ipv6-address"] and #entry["ipv6-address"] > 0)
end

local function is_lan_like(name)
    return type(name) == "string" and (
        name == "loopback" or
        name == "lan" or
        name:match("^lan%d*$") or
        name:match("^guest")
    )
end

local function get_default_wan_name()
    local uci = require("luci.model.uci").cursor()
    local entries = get_interface_dump_entries()
    local best_name = nil
    local best_score = -1

    for _, entry in ipairs(entries) do
        local name = entry.interface
        if name and name ~= "" and not is_lan_like(name) then
            local score = 0

            if entry_has_default_route(entry) then
                score = score + 100
            end
            if entry.up then
                score = score + 50
            end
            if entry_has_address(entry) then
                score = score + 20
            end
            if name == "wwan" then
                score = score + 40
            elseif name == "wan" then
                score = score + 30
            elseif name:match("wan") then
                score = score + 20
            end

            if score > best_score then
                best_name = name
                best_score = score
            end
        end
    end

    if best_name and best_score > 0 then
        return best_name
    end

    for _, fallback in ipairs({ "wwan", "wan" }) do
        if uci:get("network", fallback) then
            return fallback
        end
    end

    return best_name or "wan"
end

local function get_default_wan()
    local wan_name = get_default_wan_name()
    local status = util.ubus("network.interface." .. wan_name, "status") or {}
    local l3_device = status.l3_device or status.device or status.ifname or ""

    if l3_device == "" then
        local devices = split_words(status.device or status.ifname)
        l3_device = devices[1] or wan_name
    end

    return wan_name, status, l3_device
end

local function list_netifaces()
    local names = {}
    local out = u.exec("ls -1 /sys/class/net")

    for iface in out:gmatch("[^\n]+") do
        names[#names + 1] = iface
    end

    table.sort(names)
    return names
end

local function is_virtual_iface(iface)
    -- Allow bridge interfaces but exclude common purely virtual ones
    return iface == "lo" or
        iface:match("^docker") or
        iface:match("^veth") or
        iface:match("^ifb") or
        iface:match("^dummy") or
        iface:find("%.", 1, true) ~= nil
end

local function is_ethernet_iface(iface)
    if is_virtual_iface(iface) then
        return false
    end

    if u.file_exists("/sys/class/net/" .. iface .. "/wireless") or
        u.file_exists("/sys/class/net/" .. iface .. "/phy80211") then
        return false
    end

    if read_number("/sys/class/net/" .. iface .. "/type") ~= 1 then
        return false
    end

    local mac = (u.read_file("/sys/class/net/" .. iface .. "/address") or ""):lower()
    if mac == "" or mac == "00:00:00:00:00:00" then
        return false
    end

    return true
end

local function is_user_port(iface)
    return u.file_exists("/sys/class/net/" .. iface .. "/phys_port_name") or
        u.file_exists("/sys/class/net/" .. iface .. "/phys_switch_id") or
        iface:match("^lan%d+$") ~= nil or
        iface:match("^wan%d*$") ~= nil
end

local function read_master_name(iface)
    local info = u.exec("readlink /sys/class/net/" .. iface .. "/master")
    return info:match("([^/%s]+)%s*$") or ""
end

local function collect_logical_interfaces()
    local uci = require("luci.model.uci").cursor()
    local interfaces = {}

    uci:foreach("network", "interface", function(s)
        if s[".name"] ~= "loopback" then
            local devices = split_words(s.device or s.ifname)
            interfaces[#interfaces + 1] = {
                name = s[".name"],
                devices = devices
            }
        end
    end)

    return interfaces
end

local function sort_ports(a, b)
    local order = {
        wan = 0,
        wan1 = 1
    }

    if order[a.name] and order[b.name] then
        return order[a.name] < order[b.name]
    end

    if order[a.name] then
        return true
    end

    if order[b.name] then
        return false
    end

    local a_lan = tonumber(a.name:match("^lan(%d+)$"))
    local b_lan = tonumber(b.name:match("^lan(%d+)$"))
    if a_lan and b_lan then
        return a_lan < b_lan
    end

    if a_lan then
        return true
    end

    if b_lan then
        return false
    end

    return a.name < b.name
end

local function build_port_list()
    local raw_candidates = {}
    local user_port_count = 0
    local logical_interfaces = collect_logical_interfaces()

    for _, iface in ipairs(list_netifaces()) do
        if is_ethernet_iface(iface) then
            raw_candidates[#raw_candidates + 1] = iface
            if is_user_port(iface) then
                user_port_count = user_port_count + 1
            end
        end
    end

    local ports = {}

    for _, iface in ipairs(raw_candidates) do
        if user_port_count == 0 or is_user_port(iface) then
            local master = read_master_name(iface)
            local port = {
                name = iface,
                macAddress = ((u.read_file("/sys/class/net/" .. iface .. "/address") or ""):upper()),
                linkSpeed = "",
                linkState = "DOWN",
                rx_packets = read_number("/sys/class/net/" .. iface .. "/statistics/rx_packets"),
                tx_packets = read_number("/sys/class/net/" .. iface .. "/statistics/tx_packets"),
                interfaceNames = {},
                master = master,
                duplex = u.read_file("/sys/class/net/" .. iface .. "/duplex") or ""
            }

            local operstate = (u.read_file("/sys/class/net/" .. iface .. "/operstate") or ""):lower()
            if operstate == "up" then
                port.linkState = "UP"
            end

            local speed = read_number("/sys/class/net/" .. iface .. "/speed")
            if speed > 0 then
                port.linkSpeed = speed .. "Mbps"
            end

            local names = {}
            local seen = {}
            for _, iface_conf in ipairs(logical_interfaces) do
                for _, dev in ipairs(iface_conf.devices) do
                    if dev == iface or (master ~= "" and dev == master) then
                        add_unique(names, seen, iface_conf.name)
                    end
                end
            end
            port.interfaceNames = names

            ports[#ports + 1] = port
        end
    end

    table.sort(ports, sort_ports)
    return ports
end

local function get_firewall_map()
    local uci = require("luci.model.uci").cursor()
    local firewall_map = {}

    uci:foreach("firewall", "zone", function(s)
        local zone_name = s.name or s[".name"]
        for _, name in ipairs(split_words(s.network)) do
            firewall_map[name] = zone_name
        end
    end)

    return firewall_map
end

local function get_interface_device_names(interface_section, devices)
    local device_names = {}
    local seen = {}
    local wanted = split_words(interface_section.device or interface_section.ifname)

    for _, dev in ipairs(wanted) do
        add_unique(device_names, seen, dev)
        if dev:match("^br%-") then
            for _, port in ipairs(devices) do
                if port.master == dev then
                    add_unique(device_names, seen, port.name)
                end
            end
        end
    end

    local filtered = {}
    local device_lookup = {}
    for _, dev in ipairs(devices) do
        device_lookup[dev.name] = true
    end

    for _, name in ipairs(device_names) do
        if device_lookup[name] then
            filtered[#filtered + 1] = name
        end
    end

    return filtered
end

local function ensure_interface_section(uci, name)
    if not uci:get("network", name) then
        uci:section("network", "interface", name, {})
    end
end

local function set_interface_device(uci, name, devices, firewall_type)
    if #devices == 0 then
        uci:delete("network", name, "device")
        uci:delete("network", name, "ifname")
        return
    end

    if firewall_type == "lan" and #devices > 1 then
        local bridge_name = "br-" .. name
        local section_name = "dashboard_" .. name .. "_device"

        uci:section("network", "device", section_name, {
            name = bridge_name,
            type = "bridge"
        })
        uci:set_list("network", section_name, "ports", devices)
        uci:set("network", name, "device", bridge_name)
    else
        uci:set("network", name, "device", devices[1])
    end

    uci:delete("network", name, "ifname")
end

local function update_firewall_membership(uci, iface_name, firewall_type)
    if firewall_type ~= "lan" and firewall_type ~= "wan" then
        return
    end

    local zone_sections = {}
    uci:foreach("firewall", "zone", function(s)
        zone_sections[#zone_sections + 1] = s[".name"]
    end)

    for _, section_name in ipairs(zone_sections) do
        local networks = split_words(uci:get("firewall", section_name, "network"))
        local filtered = {}
        local seen = {}

        for _, network_name in ipairs(networks) do
            if network_name ~= iface_name then
                add_unique(filtered, seen, network_name)
            end
        end

        if (uci:get("firewall", section_name, "name") or section_name) == firewall_type then
            add_unique(filtered, seen, iface_name)
        end

        if #filtered > 0 then
            uci:set_list("firewall", section_name, "network", filtered)
        else
            uci:delete("firewall", section_name, "network")
        end
    end
end

local function ip_to_u32(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a = tonumber(a)
    b = tonumber(b)
    c = tonumber(c)
    d = tonumber(d)

    if not a or not b or not c or not d then
        return nil
    end

    return a * 16777216 + b * 65536 + c * 256 + d
end

local function mask_to_u32(mask)
    local mask_num = tonumber(mask)
    if not mask_num or mask_num <= 0 then
        return 0
    end
    if mask_num >= 32 then
        return 4294967295
    end

    return 4294967296 - 2 ^ (32 - mask_num)
end

local function ip_in_network(ip, network_ip, mask)
    local ip_num = ip_to_u32(ip)
    local network_num = ip_to_u32(network_ip)
    local mask_num = tonumber(mask)

    if not ip_num or not network_num or not mask_num then
        return false
    end

    local host_bits = 32 - math.max(0, math.min(32, mask_num))
    local block_size = 2 ^ host_bits

    return math.floor(ip_num / block_size) == math.floor(network_num / block_size)
end

local function build_local_client_context()
    local firewall_map = get_firewall_map()
    local dump_entries = get_interface_dump_entries()
    local wan_name, _, wan_l3_device = get_default_wan()
    local context = {
        devices = {},
        networks = {},
        wan_l3_device = wan_l3_device
    }

    for _, entry in ipairs(dump_entries) do
        local name = entry.interface
        local zone = firewall_map[name]
        local is_uplink = name == wan_name or zone == "wan"

        if name and not is_uplink then
            for _, dev in ipairs(split_words(entry.l3_device or entry.device or entry.ifname)) do
                context.devices[dev] = true
            end

            if entry.device and entry.device ~= "" then
                context.devices[entry.device] = true
            end

            for _, addr in ipairs(entry["ipv4-address"] or {}) do
                if addr.address and tonumber(addr.mask) then
                    context.networks[#context.networks + 1] = {
                        address = addr.address,
                        mask = tonumber(addr.mask)
                    }
                end
            end
        end
    end

    return context
end

local function is_local_client_ip(ip, context)
    for _, network in ipairs(context.networks) do
        if ip_in_network(ip, network.address, network.mask) then
            return true
        end
    end

    return false
end

local function should_keep_client(ip, iface, context)
    if not ip or ip == "" then
        return false
    end

    if iface and iface ~= "" then
        if context.devices[iface] then
            return true
        end

        if iface == context.wan_l3_device then
            return false
        end
    end

    return is_local_client_ip(ip, context)
end

--- GET /u/network/status/
-- Returns WAN/LAN connection info, IP, DNS, proto, uptime
function M.status()
    local uci = require("luci.model.uci").cursor()
    local result = {}
    local wan_ifname, wan, _ = get_default_wan()
    local wan6_name = wan_ifname == "wan" and "wan6" or (wan_ifname .. "6")
    local wan6 = util.ubus("network.interface." .. wan6_name, "status") or util.ubus("network.interface.wan6", "status") or {}

    result.defaultInterface = wan_ifname

    result.ipv4addr = ""
    if wan["ipv4-address"] and wan["ipv4-address"][1] then
        result.ipv4addr = wan["ipv4-address"][1].address or ""
    end

    result.ipv6addr = ""
    if wan6["ipv6-address"] and wan6["ipv6-address"][1] then
        result.ipv6addr = wan6["ipv6-address"][1].address or ""
    elseif wan["ipv6-address"] and wan["ipv6-address"][1] then
        result.ipv6addr = wan["ipv6-address"][1].address or ""
    end

    result.proto = uci:get("network", wan_ifname, "proto") or "dhcp"
    result.dnsList = wan["dns-server"] or wan6["dns-server"] or {}

    local custom_dns = uci:get_list("network", wan_ifname, "dns")
    if custom_dns and #custom_dns > 0 then
        result.dnsProto = "manual"
    else
        result.dnsProto = "auto"
    end

    result.uptimeStamp = wan.uptime or 0

    -- Public IP Detection (v1.3.2)
    local public_ip = ""
    local cache_file = "/tmp/public_ip.txt"
    local now = os.time()
    local f = io.open(cache_file, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local sip = raw:match("ip=([^%s\n]+)")
        local country = raw:match("country=([^%s\n]+)")
        local isp = raw:match("isp=([^%s\n]+)")
        
        if sip then
            public_ip = sip
            if country or isp then
                public_ip = public_ip .. " (" .. (country or "") .. (isp and (" " .. isp) or "") .. ")"
            end
        end
    end

    -- Trigger background update if cache is empty or older than 10 mins
    local last_update = (util.lsblk and util.lsblk.mtime) and util.lsblk.mtime(cache_file) or 0
    if public_ip == "" or (now - last_update > 600) then
        os.execute("curl -skL https://ipleak.net/json/ | jsonfilter -e 'ip=@.ip' -e 'country=@.country_name' -e 'isp=@.isp_name' > " .. cache_file .. " 2>/dev/null &")
    end
    result.publicIP = public_ip

    if wan.up or result.ipv4addr ~= "" or result.ipv6addr ~= "" or #result.dnsList > 0 then
        result.networkInfo = (#result.dnsList > 0) and "netSuccess" or "dnsFailed"
    else
        result.networkInfo = "netFailed"
    end

    u.json_success(result)
end

--- GET /u/network/statistics/
-- Returns the traffic timeline expected by the bundled frontend
function M.statistics()
    local _, _, l3_device = get_default_wan()
    local rx_path = "/sys/class/net/" .. l3_device .. "/statistics/rx_bytes"
    local tx_path = "/sys/class/net/" .. l3_device .. "/statistics/tx_bytes"
    local state = load_json_file(TRAFFIC_STATE_FILE)
    local now = os.time()
    local items = state.items or {}

    if u.file_exists(rx_path) and u.file_exists(tx_path) then
        local current_rx = read_number(rx_path)
        local current_tx = read_number(tx_path)

        if state.iface == l3_device and
            type(state.last_ts) == "number" and
            type(state.last_rx) == "number" and
            type(state.last_tx) == "number" and
            now > state.last_ts then
            local delta_t = math.max(1, now - state.last_ts)
            local delta_rx = math.max(0, current_rx - state.last_rx)
            local delta_tx = math.max(0, current_tx - state.last_tx)

            items[#items + 1] = {
                startTime = state.last_ts,
                endTime = now,
                downloadSpeed = math.floor(delta_rx / delta_t),
                uploadSpeed = math.floor(delta_tx / delta_t)
            }
        end

        while #items > TRAFFIC_SLOTS do
            table.remove(items, 1)
        end

        save_json_file(TRAFFIC_STATE_FILE, {
            iface = l3_device,
            last_ts = now,
            last_rx = current_rx,
            last_tx = current_tx,
            items = items
        })
    end

    u.json_success({
        items = items,
        slots = TRAFFIC_SLOTS
    })
end

--- GET /network/device/list/
-- Returns list of connected devices from DHCP leases + ARP table
function M.device_list()
    local devices = {}
    local seen = {}
    local context = build_local_client_context()

    local function add_device(mac, ip, name, timestamp, iface)
        if not should_keep_client(ip, iface, context) then
            return
        end

        local key = (mac and mac ~= "00:00:00:00:00:00") and mac or ip
        if not key or key == "" or seen[key] then
            return
        end

        seen[key] = true
        devices[#devices + 1] = {
            mac = mac or "",
            ip = ip or "",
            name = name or "",
            timestamp = tonumber(timestamp) or 0
        }
    end

    local leases = u.read_file_all("/tmp/dhcp.leases") or ""
    for line in leases:gmatch("[^\n]+") do
        local ts, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac then
            mac = mac:upper()
            add_device(mac, ip, (name and name ~= "*") and name or "", ts, nil)
        end
    end

    local arp = u.read_file_all("/proc/net/arp") or ""
    for line in arp:gmatch("[^\n]+") do
        local ip, _, flags, mac, _, iface = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        -- Flags 0x2 means the ARP entry is valid
        if mac and mac ~= "00:00:00:00:00:00" and ip ~= "IP" and flags == "0x2" then
            mac = mac:upper()
            add_device(mac, ip, "", 0, iface)
        end
    end

    u.json_success({ devices = devices })
end

--- GET /network/port/list/
-- Returns filtered physical network port status
function M.port_list()
    u.json_success({ ports = build_port_list() })
end

--- GET /network/interface/config/
-- Returns network interface configuration
function M.interface_config_get()
    local uci = require("luci.model.uci").cursor()
    local firewall_map = get_firewall_map()
    local devices = build_port_list()
    local interfaces = {}

    uci:foreach("network", "interface", function(s)
        local name = s[".name"]
        if name ~= "loopback" then
            local firewall_type = firewall_map[name]
            if not firewall_type then
                if name == "wan" or name:match("^wan%d*$") then
                    firewall_type = "wan"
                elseif name == "lan" or name:match("^lan%d*$") then
                    firewall_type = "lan"
                end
            end

            if firewall_type == "wan" or firewall_type == "lan" then
                interfaces[#interfaces + 1] = {
                    name = name,
                    proto = s.proto or "dhcp",
                    deviceNames = get_interface_device_names(s, devices),
                    firewallType = firewall_type
                }
            end
        end
    end)

    u.json_success({
        devices = devices,
        interfaces = interfaces
    })
end

--- POST /network/interface/config/
-- Updates network interface configuration
function M.interface_config_post()
    local body = u.get_request_body()
    local configs = body.configs

    if type(configs) ~= "table" then
        u.json_success({ status = "ok" })
        return
    end

    local uci = require("luci.model.uci").cursor()

    for _, config in ipairs(configs) do
        if type(config) == "table" and config.name and config.name ~= "" then
            ensure_interface_section(uci, config.name)

            if config.proto and config.proto ~= "" then
                uci:set("network", config.name, "proto", config.proto)
            end

            local device_names = split_words(config.devices)
            set_interface_device(uci, config.name, device_names, config.firewallType)
            update_firewall_membership(uci, config.name, config.firewallType)
        end
    end

    uci:commit("network")
    uci:commit("firewall")
    os.execute("/etc/init.d/network reload >/dev/null 2>&1 &")

    u.json_success({ status = "ok" })
end

--- POST /network/checkPublicNet/
-- Checks Internet reachability using upstream interface state
function M.check_public_net()
    local _, wan, _ = get_default_wan()
    local dns_list = wan["dns-server"] or {}

    u.json_success({
        reachable = (wan.up or ((wan["ipv4-address"] and #wan["ipv4-address"] > 0) or (wan["ipv6-address"] and #wan["ipv6-address"] > 0))) and true or false,
        dns = #dns_list > 0
    })
end

return M
