-- REFAudio UTF-8 文件桥；仅由帧线程调用，固定 ASCII 控制文件由 DLL 工作线程消费。
local Bridge = {}

local COMMAND = "REFAudio\\audio_utf8_command.txt"
local PAYLOAD = "REFAudio\\audio_utf8_payload.bin"
-- 单一响应路径由 DLL 原子替换；仍按请求 ID 校验，旧响应不会提前完成新请求。
local RESPONSE = "REFAudio\\audio_utf8_response.txt"

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function write(path, value)
    local file = io.open(path, "wb")
    if not file then return false end
    local ok = file:write(value)
    file:close()
    return ok ~= nil
end

local function hex(value)
    return (value:gsub(".", function(char) return string.format("%02x", string.byte(char)) end))
end

local function unhex(value)
    if #value % 2 ~= 0 then return nil end
    local out = {}
    for index = 1, #value, 2 do
        local byte = tonumber(string.sub(value, index, index + 1), 16)
        if not byte then return nil end
        out[#out + 1] = string.char(byte)
    end
    return table.concat(out)
end

local function wait_response(id, timeout)
    local deadline = os.clock() + (timeout or 0.5)
    repeat
        local response = read(RESPONSE)
        local response_id, state, payload = response and string.match(response, "^(.-)\t(.-)\t(.-)\r?\n?$")
        if response_id == id then
            if state == "ok" then return true, unhex(payload or "") end
            return false, payload or "utf8_io"
        end
    until os.clock() >= deadline
    return false, "utf8_bridge_timeout"
end

local next_id = 0
local busy = false

local function request(action, path, content)
    if busy then return false, "utf8_bridge_busy" end
    busy = true
    next_id = next_id + 1
    local id = tostring(os.time()) .. "-" .. tostring(next_id)
    if content ~= nil and not write(PAYLOAD, content) then busy = false; return false, "utf8_payload_write_failed" end
    local command = table.concat({"voice-controller", id, action, hex(path),
        content ~= nil and hex(content) or ""}, "\t")
    if not write(COMMAND, command) then busy = false; return false, "utf8_command_write_failed" end
    local ok, value = wait_response(id)
    busy = false
    return ok, value
end

function Bridge.read(path)
    local ok, value = request("utf8_read", path)
    return ok and value or nil
end

function Bridge.write(path, content)
    local ok, error = request("utf8_write", path, content)
    if ok then return true end
    -- 写入响应可能因帧线程时序丢失，但 DLL 已完成写入；用独立 read 请求确认最终内容。
    if error == "utf8_io" or error == "utf8_bridge_timeout" then
        for _ = 1, 3 do
            local read_ok, current = request("utf8_read", path)
            if read_ok and current == content then return true end
        end
        ok, error = request("utf8_write", path, content)
    end
    return ok, error
end

return Bridge
