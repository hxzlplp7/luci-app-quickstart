-- Dashboard shared utilities
-- 保持极简，仅保留必要函数

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local util = require "luci.util"

local M = {}

function M.json_success(data)
    http.prepare_content("application/json")
    http.write(jsonc.stringify({
        success = 200,
        result = data or {}
    }))
end

function M.check_session()
    local sdat, sid
    for _, key in ipairs({"sysauth_https", "sysauth_http", "sysauth"}) do
        sid = http.getcookie(key)
        if sid then
            sdat = util.ubus("session", "get", { ubus_rpc_session = sid })
            if type(sdat) == "table" and
               type(sdat.values) == "table" and
               type(sdat.values.token) == "string" then
                return sid, sdat.values
            end
        end
    end
    return nil, nil
end

function M.read_file(path)
    local f = io.open(path, "r")
    if f then
        local content = f:read("*l")
        f:close()
        return content
    end
    return nil
end

function M.read_file_all(path)
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        return content
    end
    return nil
end

function M.write_to_file(path, content)
    local f = io.open(path, "w")
    if f then
        f:write(content)
        f:close()
        return true
    end
    return false
end

function M.exec(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if p then
        local output = p:read("*a") or ""
        p:close()
        return output
    end
    return ""
end

return M
