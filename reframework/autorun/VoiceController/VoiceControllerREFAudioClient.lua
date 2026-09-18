-- VoiceController REFAudio 命令客户端。
-- Hook 线程只能向内存队列追加；帧线程独占后端检查、音频文件检查和命令文件写入。

local Client = {}

local BACKEND_PATH = "REFAudio\\audio_backend.txt"
local COMMAND_PATH = "REFAudio\\audio_command.txt"
local MIN_COMMAND_INTERVAL = 0.05
local MAX_PENDING = 64
local check_backend

local function read_all(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function write_all(path, content)
    local file = io.open(path, "wb")
    if not file then return false, "command_file_busy" end
    local write_ok = file:write(content)
    file:close()
    if not write_ok then return false, "command_write_failed" end
    return true
end

local function clean_field(value)
    local cleaned = tostring(value):gsub("[\t\r\n]", "")
    return cleaned
end

-- 创建单写者客户端；通道 ID 使用独立高位区间，避免与手工测试通道冲突。
function Client.new(file_api)
    file_api = file_api or {}
    return {
        session_id = tostring(os.time()) .. "-vc",
        command_id = 0,
        next_channel_id = 1447235584,
        pending = {},
        last_write = -MIN_COMMAND_INTERVAL,
        backend_checked_at = -1,
        backend_ready = false,
        group_dirs_ready = false,
        submitted = 0,
        failed = 0,
        dropped = 0,
        last_error = nil,
        preflight_checked_at = -1,
        preflight_file = nil,
        preflight_ready = false,
        preflight_error = nil,
        read_all = file_api.read_all or read_all,
        file_exists = file_api.file_exists or file_exists,
        write_all = file_api.write_all or write_all
    }
end

-- 帧线程缓存替换前置条件；Hook 仅读取结果，绝不自行访问后端或音频文件。
function Client.preflight(client, path, now)
    if client.preflight_file == path and now - client.preflight_checked_at < 1.0 then
        return client.preflight_ready, client.preflight_error
    end
    client.preflight_checked_at = now
    client.preflight_file = path
    client.preflight_ready = false

    if not check_backend(client, now) then
        client.preflight_error = "backend_unavailable"
        return false, client.preflight_error
    end
    if not client.file_exists(path) then
        client.preflight_error = "audio_file_missing"
        return false, client.preflight_error
    end
    client.preflight_ready = true
    client.preflight_error = nil
    return true, nil
end

-- 从 Hook 线程追加已校验的播放描述；不访问文件系统。
function Client.enqueue_load(client, spec)
    if #client.pending >= MAX_PENDING then
        client.dropped = client.dropped + 1
        client.last_error = "queue_full"
        return false
    end
    client.pending[#client.pending + 1] = spec
    return true
end

-- 从 REFF/帧线程排队创建受限分组目录；实际文件系统操作由 REFAudio 工作线程完成。
function Client.enqueue_ensure_group_directory(client, path)
    return Client.enqueue_load(client, {
        source = "group-directory",
        action = "ensure_dir",
        file = path,
        stable_key = path
    })
end

check_backend = function(client, now)
    if now - client.backend_checked_at < 1.0 then return client.backend_ready end
    client.backend_checked_at = now
    local marker = client.read_all(BACKEND_PATH)
    client.backend_ready = marker ~= nil
        and string.find(marker, "REFAudio\t1", 1, true) ~= nil
        and string.find(marker, "multichannel=1", 1, true) ~= nil
    client.group_dirs_ready = client.backend_ready
        and string.find(marker, "group_dirs=1", 1, true) ~= nil
    return client.backend_ready
end

function Client.refresh_backend(client, now)
    return check_backend(client, now)
end

local function fail_front(client, reason)
    local spec = client.pending[1]
    table.remove(client.pending, 1)
    client.failed = client.failed + 1
    client.last_error = reason
    return {
        kind = "error",
        reason = reason,
        source = spec and spec.source or "replacement",
        stable_key = spec and spec.stable_key or nil
    }
end

-- 帧线程每次最多提交一条命令，保证原生端 20ms 轮询能看到每次完整写入。
function Client.tick(client, now)
    if #client.pending == 0 or now - client.last_write < MIN_COMMAND_INTERVAL then return nil end
    if not check_backend(client, now) then return fail_front(client, "backend_unavailable") end

    local spec = client.pending[1]
    local action = spec.action or "load"
    if action == "load" and not client.file_exists(spec.file) then
        return fail_front(client, "audio_file_missing")
    end

    local channel_id = client.next_channel_id
    client.next_channel_id = client.next_channel_id + 1
    client.command_id = client.command_id + 1
    local fields = {
        client.session_id,
        tostring(client.command_id),
        action,
        tostring(channel_id),
        clean_field(spec.file),
        clean_field(spec.volume or 1),
        clean_field(spec.speed or 1),
        clean_field((spec.max_duration_ms or 0) / 1000)
    }

    local write_ok, write_error = client.write_all(COMMAND_PATH, table.concat(fields, "\t"))
    if not write_ok then
        client.failed = client.failed + 1
        client.last_error = write_error or "command_write_failed"
        client.last_write = now
        return {
            kind = "retry",
            reason = client.last_error,
            source = spec.source or "replacement",
            stable_key = spec.stable_key
        }
    end

    table.remove(client.pending, 1)
    client.last_write = now
    client.submitted = client.submitted + 1
    client.last_error = nil
    return {
        kind = "submitted",
        channel_id = channel_id,
        source = spec.source or "replacement",
        stable_key = spec.stable_key
    }
end

function Client.get_status(client)
    return {
        backendReady = client.backend_ready,
        groupDirectoriesReady = client.group_dirs_ready,
        pending = #client.pending,
        submitted = client.submitted,
        failed = client.failed,
        dropped = client.dropped,
        lastError = client.last_error,
        preflightReady = client.preflight_ready,
        preflightError = client.preflight_error
    }
end

return Client
