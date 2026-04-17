local http = require("luci.http")
local jsonc = require("luci.jsonc")
local response = require("luci.dashboard.response")
local feature = require("luci.dashboard.services.feature")

local M = {}

local function write(payload)
  http.prepare_content("application/json")
  http.write(jsonc.stringify(payload))
end

function M.info()
  local payload, err, details = feature.get_info()
  if not payload then
    write(response.fail(err, "invalid feature info", details))
    return
  end

  write(response.ok(payload))
end

function M.classes()
  local payload, err, details = feature.get_classes()
  if not payload then
    write(response.fail(err, "invalid feature classes", details))
    return
  end

  write(response.ok(payload))
end

function M.status()
  write(response.ok(feature.get_status()))
end

function M.upload()
  local upload = {
    path = nil,
    name = nil,
    size = 0,
    error = nil
  }
  local temp_path = os.tmpname()
  local file_handle = nil

  http.setfilehandler(function(meta, chunk, eof)
    if meta and meta.name == "file" and not file_handle then
      upload.name = meta.file or "feature-pack.tar.gz"
      file_handle = io.open(temp_path, "wb")
      if file_handle then
        upload.path = temp_path
      else
        upload.error = "upload_open_failed"
      end
    end

    if file_handle and chunk and #chunk > 0 then
      file_handle:write(chunk)
      upload.size = upload.size + #chunk
    end

    if file_handle and eof then
      file_handle:close()
      file_handle = nil
    end
  end)

  http.formvalue("file")

  if upload.error then
    write(response.fail(upload.error, "failed to create temporary upload file"))
    return
  end

  if not upload.path then
    write(response.fail("invalid_arg", "missing file upload"))
    return
  end

  local payload, err, details = feature.import_bundle(upload.path, upload.name, upload.size)
  os.remove(upload.path)

  if not payload then
    write(response.fail(err or "invalid_arg", "invalid feature bundle", details))
    return
  end

  write(response.ok(payload))
end

return M
