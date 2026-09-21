-- VoiceController REFAudio 命令客户端。
-- Hook 线程只能向内存队列追加；帧线程独占后端检查、音频文件检查和命令文件写入。

local Client = {}

local BACKEND_PATH = "REFAudio\\audio_backend.txt"
local COMMAND_PATH = "REFAudio\\audio_command.txt"
local MIN_COMMAND_INTERVAL = 0.05
local MAX_PENDING = 64
local SPATIAL_UPDATE_INTERVAL = 0.1
local MAX_SPATIAL_UPDATES_PER_TICK = 4
local DISTANCE_REFERENCE = 1.5
local DISTANCE_MAX = 40.0
local DISTANCE_ROLLOFF = 1.0
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

-- 读取游戏对象世界坐标；只在帧线程执行，坐标不可用时保持规则原始音量。
local function read_position(object)
    if object == nil then return nil end
    local transform_ok, transform = pcall(object.call, object, "get_Transform")
    if not transform_ok or transform == nil then return nil end
    local position_ok, position = pcall(transform.call, transform, "get_Position")
    if not position_ok or position == nil then return nil end
    local x, y, z
    pcall(function() x, y, z = position.x, position.y, position.z end)
    if x == nil then pcall(function() x = position:get_x() end) end
    if y == nil then pcall(function() y = position:get_y() end) end
    if z == nil then pcall(function() z = position:get_z() end) end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y or not z then return nil end
    return x, y, z
end

local function read_vector(value)
    if value == nil then return nil end
    local x, y, z
    pcall(function() x, y, z = value.x, value.y, value.z end)
    if x == nil then pcall(function() x = value:get_x() end) end
    if y == nil then pcall(function() y = value:get_y() end) end
    if z == nil then pcall(function() z = value:get_z() end) end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y or not z then return nil end
    return {x, y, z}
end

-- 帧线程读取声源与主相机姿态；BASS 监听器跟随相机，坐标不可用时回退玩家位置和固定朝向。
local function read_spatial_state(spec)
    local sx, sy, sz = read_position(spec.source_object)
    if not sx then return nil end
    local listener, front, top
    if sdk and sdk.get_primary_camera then
        pcall(function()
            local camera = sdk.get_primary_camera()
            local matrix = camera and camera:call("get_WorldMatrix")
            listener = matrix and read_vector(matrix[3]) or nil
            front = matrix and read_vector(matrix[2]) or nil
            top = matrix and read_vector(matrix[1]) or nil
        end)
    end
    if not listener then
        local lx, ly, lz = read_position(spec.listener_object)
        if lx then listener = {lx, ly, lz} end
    end
    if not listener then return nil end
    return {
        source = {sx, sy, sz},
        listener = listener,
        front = front or {0, 0, 1},
        top = top or {0, 1, 0}
    }
end

-- 计算线性距离衰减；不改变规则音量上限，超出最大距离时静音。
local function apply_distance_attenuation(spec)
    local volume = tonumber(spec.volume) or 1.5
    if spec.distance_enabled ~= true then return volume end
    local sx, sy, sz = read_position(spec.source_object)
    local lx, ly, lz = read_position(spec.listener_object)
    if not sx or not lx then return volume end
    local dx, dy, dz = sx - lx, sy - ly, sz - lz
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    local reference = tonumber(spec.reference_distance) or DISTANCE_REFERENCE
    local maximum = tonumber(spec.max_distance) or DISTANCE_MAX
    local rolloff = tonumber(spec.rolloff) or DISTANCE_ROLLOFF
    if distance >= maximum then return 0 end
    if distance <= reference then return volume end
    local attenuation = reference / (reference + rolloff * (distance - reference))
    return volume * math.max(0, math.min(1, attenuation))
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
        spatial_3d_ready = false,
        spatial_batch_ready = false,
        group_dirs_ready = false,
        submitted = 0,
        failed = 0,
        dropped = 0,
        last_error = nil,
        preflight_checked_at = -1,
        preflight_file = nil,
        preflight_ready = false,
        preflight_error = nil,
        spatial_channels = {},
        spatial_snapshot = nil,
        spatial_snapshot_at = -1,
        spatial_active_ids = {},
        pending_volume_channels = {},
        pending_spatial_batch = false,
        spatial_cursor = nil,
        next_spatial_update = 0,
        read_spatial_state = file_api.read_spatial_state or read_spatial_state,
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

-- 向原生端追加指定通道的音量更新；更新仍由单写者命令队列节流。
function Client.enqueue_channel_volume(client, channel_id, volume, stable_key)
    if client.pending_volume_channels[channel_id] then return true end
    if #client.pending >= MAX_PENDING then
        client.dropped = client.dropped + 1
        client.last_error = "queue_full"
        return false
    end
    client.pending[#client.pending + 1] = {
        source = "spatial",
        action = "volume",
        channel_id = channel_id,
        volume = volume,
        stable_key = stable_key
    }
    client.pending_volume_channels[channel_id] = true
    return true
end

-- 向原生端追加空间坐标更新；同一通道只允许一条待处理命令，避免移动时淹没队列。
function Client.enqueue_channel_position(client, channel_id, spatial, stable_key)
    if client.pending_volume_channels[channel_id] then return true end
    if #client.pending >= MAX_PENDING then
        client.dropped = client.dropped + 1
        client.last_error = "queue_full"
        return false
    end
    client.pending[#client.pending + 1] = {
        source = "spatial",
        action = "position3d",
        channel_id = channel_id,
        spatial = spatial,
        stable_key = stable_key
    }
    client.pending_volume_channels[channel_id] = true
    return true
end

-- 将多个 3D 声源与同一相机监听器合并为一条命令，避免多声道更新超过文件协议吞吐量。
function Client.enqueue_spatial_batch(client, updates, listener)
    if client.pending_spatial_batch or #updates == 0 then return false end
    if #client.pending >= MAX_PENDING then
        client.dropped = client.dropped + 1
        client.last_error = "queue_full"
        return false
    end
    client.pending[#client.pending + 1] = {
        source = "spatial",
        action = "spatial_batch",
        updates = updates,
        listener = listener
    }
    client.pending_spatial_batch = true
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
    client.spatial_3d_ready = client.backend_ready
        and string.find(marker, "spatial3d=1", 1, true) ~= nil
    client.spatial_batch_ready = client.spatial_3d_ready
        and string.find(marker, "spatial_batch=1", 1, true) ~= nil
    return client.backend_ready
end

function Client.refresh_backend(client, now)
    return check_backend(client, now)
end

local function fail_front(client, reason)
    local spec = client.pending[1]
    table.remove(client.pending, 1)
    if spec and (spec.action == "volume" or spec.action == "position3d") then
        client.pending_volume_channels[spec.channel_id] = nil
    end
    if spec and spec.action == "spatial_batch" then client.pending_spatial_batch = false end
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

    local channel_id = spec.channel_id
    if action == "load" then
        channel_id = client.next_channel_id
        client.next_channel_id = client.next_channel_id + 1
    end
    client.command_id = client.command_id + 1
    local fields
    if action == "load" then
        local spatial = spec.distance_enabled == true and client.spatial_3d_ready
            and client.read_spatial_state(spec) or nil
        if spatial then
            fields = {
                client.session_id, tostring(client.command_id), "load3d", tostring(channel_id),
                clean_field(spec.file), clean_field(spec.volume or 1.5), clean_field(spec.speed or 1),
                clean_field((spec.max_duration_ms or 0) / 1000),
                clean_field(spatial.source[1]), clean_field(spatial.source[2]), clean_field(spatial.source[3]),
                clean_field(spec.reference_distance or DISTANCE_REFERENCE),
                clean_field(spec.max_distance or DISTANCE_MAX),
                clean_field(spatial.listener[1]), clean_field(spatial.listener[2]), clean_field(spatial.listener[3]),
                clean_field(spatial.front[1]), clean_field(spatial.front[2]), clean_field(spatial.front[3]),
                clean_field(spatial.top[1]), clean_field(spatial.top[2]), clean_field(spatial.top[3])
            }
            spec.spatial_3d = true
        else
            fields = {
                client.session_id, tostring(client.command_id), action, tostring(channel_id),
                clean_field(spec.file), clean_field(apply_distance_attenuation(spec)),
                clean_field(spec.speed or 1), clean_field((spec.max_duration_ms or 0) / 1000)
            }
            spec.spatial_3d = false
        end
    elseif action == "volume" then
        fields = {
            client.session_id, tostring(client.command_id), action, tostring(channel_id),
            clean_field(spec.volume or 1.5)
        }
    elseif action == "position3d" then
        local spatial = spec.spatial
        fields = {
            client.session_id, tostring(client.command_id), action, tostring(channel_id),
            clean_field(spatial.source[1]), clean_field(spatial.source[2]), clean_field(spatial.source[3]),
            clean_field(spatial.listener[1]), clean_field(spatial.listener[2]), clean_field(spatial.listener[3]),
            clean_field(spatial.front[1]), clean_field(spatial.front[2]), clean_field(spatial.front[3]),
            clean_field(spatial.top[1]), clean_field(spatial.top[2]), clean_field(spatial.top[3])
        }
    elseif action == "spatial_batch" then
        local listener = spec.listener
        fields = {
            client.session_id, tostring(client.command_id), action, "0",
            clean_field(listener.listener[1]), clean_field(listener.listener[2]),
            clean_field(listener.listener[3]), clean_field(listener.front[1]),
            clean_field(listener.front[2]), clean_field(listener.front[3]),
            clean_field(listener.top[1]), clean_field(listener.top[2]),
            clean_field(listener.top[3])
        }
        for _, update in ipairs(spec.updates) do
            fields[#fields + 1] = clean_field(update.channel_id)
            fields[#fields + 1] = clean_field(update.spatial.source[1])
            fields[#fields + 1] = clean_field(update.spatial.source[2])
            fields[#fields + 1] = clean_field(update.spatial.source[3])
        end
    else
        fields = {client.session_id, tostring(client.command_id), action, "0", clean_field(spec.file)}
    end

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
    if action == "volume" or action == "position3d" then
        client.pending_volume_channels[channel_id] = nil
    end
    if action == "spatial_batch" then client.pending_spatial_batch = false end
    client.last_write = now
    client.submitted = client.submitted + 1
    if action == "load" and spec.distance_enabled == true then
        client.spatial_channels[channel_id] = {spec = spec, last_update = now}
    end
    client.last_error = nil
    return {
        kind = "submitted",
        channel_id = channel_id,
        source = spec.source or "replacement",
        stable_key = spec.stable_key
    }
end

-- 帧线程按音频通道快照更新移动声源的距离音量；没有快照时保守地保留通道引用。
function Client.update_spatial(client, now)
    -- observe 模式和 Script Reset 后通常没有外部通道；此路径必须零 IO、零临时表。
    if next(client.spatial_channels) == nil then
        client.spatial_snapshot = nil
        client.spatial_snapshot_at = now
        return
    end
    if now < client.next_spatial_update then return end
    client.next_spatial_update = now + SPATIAL_UPDATE_INTERVAL
    if now - client.spatial_snapshot_at >= SPATIAL_UPDATE_INTERVAL then
        client.spatial_snapshot = client.read_all("REFAudio\\audio_channels.txt")
        client.spatial_snapshot_at = now
        local active = {}
        if type(client.spatial_snapshot) == "string" then
            for line in string.gmatch(client.spatial_snapshot, "[^\r\n]+") do
                local channel_id = string.match(line, "^(%d+)")
                if channel_id then active[channel_id] = true end
            end
            client.spatial_active_ids = active
        end
    end
    local snapshot = client.spatial_snapshot
    local updates = 0
    local spatial_ids = {}
    for channel_id, entry in pairs(client.spatial_channels) do
        -- 文件存在且为空代表原生端已没有任何活动通道，必须清理旧对象引用。
        if type(snapshot) == "string" and not client.spatial_active_ids[tostring(channel_id)] then
            client.spatial_channels[channel_id] = nil
            client.pending_volume_channels[channel_id] = nil
        elseif entry.spec.spatial_3d then
            spatial_ids[#spatial_ids + 1] = channel_id
        elseif now - entry.last_update >= SPATIAL_UPDATE_INTERVAL
            and #client.pending < MAX_PENDING
            and updates < MAX_SPATIAL_UPDATES_PER_TICK
        then
            local volume = apply_distance_attenuation(entry.spec)
            if entry.last_volume == nil or math.abs(volume - entry.last_volume) >= 0.01 then
                if Client.enqueue_channel_volume(client, channel_id, volume, entry.spec.stable_key) then
                    entry.last_volume = volume
                    entry.last_update = now
                    updates = updates + 1
                end
            else
                entry.last_update = now
            end
        end
    end
    if #spatial_ids == 0 or client.pending_spatial_batch then return end
    table.sort(spatial_ids)
    local start = 1
    if client.spatial_cursor ~= nil then
        for index, channel_id in ipairs(spatial_ids) do
            if channel_id > client.spatial_cursor then start = index break end
        end
    end
    local batch, listener = {}, nil
    for offset = 0, math.min(#spatial_ids, MAX_SPATIAL_UPDATES_PER_TICK) - 1 do
        local channel_id = spatial_ids[((start + offset - 1) % #spatial_ids) + 1]
        local entry = client.spatial_channels[channel_id]
        local spatial = entry and client.read_spatial_state(entry.spec) or nil
        if spatial then
            batch[#batch + 1] = {channel_id = channel_id, spatial = spatial, entry = entry}
            listener = listener or spatial
            client.spatial_cursor = channel_id
        end
    end
    if client.spatial_batch_ready then
        if listener and Client.enqueue_spatial_batch(client, batch, listener) then
            for _, update in ipairs(batch) do update.entry.last_update = now end
        end
    else
        for _, update in ipairs(batch) do
            if Client.enqueue_channel_position(client, update.channel_id,
                update.spatial, update.entry.spec.stable_key) then
                update.entry.last_update = now
            end
        end
    end
end

function Client.get_status(client)
    return {
        backendReady = client.backend_ready,
        groupDirectoriesReady = client.group_dirs_ready,
        spatial3dReady = client.spatial_3d_ready,
        spatialBatchReady = client.spatial_batch_ready,
        pending = #client.pending,
        submitted = client.submitted,
        failed = client.failed,
        dropped = client.dropped,
        lastError = client.last_error,
        preflightReady = client.preflight_ready,
        preflightError = client.preflight_error,
        spatialChannels = (function()
            local count = 0
            for _ in pairs(client.spatial_channels) do count = count + 1 end
            return count
        end)()
    }
end

return Client
