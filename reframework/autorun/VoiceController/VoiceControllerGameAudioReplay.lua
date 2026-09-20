-- VoiceController 游戏内音频重放队列。
-- Hook 只登记本会话请求引用；REFF 只入队稳定键；帧线程创建新 RequestInfo 并触发，人工重放期间必须屏蔽自然捕获和规则匹配。

local Replay = {}

local MAX_DESCRIPTORS = 512
local MAX_PENDING = 16
local RESOLUTION_RETRY_INTERVAL = 5
local RESOLUTION_GLOBAL_INTERVAL = 0.25
local PLAY_RESOLUTION_TIMEOUT = 5
local CALLBACK_TYPE_NONE = 0
local CREATE_REQUEST_SIGNATURE = "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)"

local function call(object, method, ...)
    if object == nil then return nil end
    local ok, result = pcall(object.call, object, method, ...)
    return ok and result or nil
end

local function find_trigger_in_list(list, descriptor)
    if list == nil then return nil end
    local items_ok, items = pcall(function() return list._items end)
    if items_ok and items ~= nil then
        for _, trigger in pairs(items) do
            if trigger ~= nil
                and tostring(call(trigger, "get_EventId")) == descriptor.event_id
                and tostring(call(trigger, "get_TriggerId")) == descriptor.trigger_id then
                return trigger
            end
        end
    end
    local count = tonumber(call(list, "get_Count")) or 0
    for index = 0, count - 1 do
        local trigger = call(list, "get_Item(System.Int32)", index) or call(list, "get_Item", index)
        if trigger ~= nil
            and tostring(call(trigger, "get_EventId")) == descriptor.event_id
            and tostring(call(trigger, "get_TriggerId")) == descriptor.trigger_id then
            return trigger
        end
    end
    return nil
end

local function find_trigger_in_array(array, descriptor)
    if array == nil then return nil end
    local items_ok, items = pcall(function() return array:get_elements() end)
    if items_ok and items ~= nil then
        for _, trigger in ipairs(items) do
            if trigger ~= nil
                and tostring(call(trigger, "get_EventId")) == descriptor.event_id
                and tostring(call(trigger, "get_TriggerId")) == descriptor.trigger_id then
                return trigger
            end
        end
    end
    return find_trigger_in_list(array, descriptor)
end

-- 帧线程从容器的稳定触发定义中按双 ID 定位条目；兼容 EMV 使用的全量触发数据列表。
local function resolve_trigger_info(descriptor)
    local direct_ok, direct_list = pcall(function() return descriptor.container._TriggerInfoList end)
    local direct = direct_ok and find_trigger_in_list(direct_list, descriptor) or nil
    if direct then return direct end

    local all_ok, all_data = pcall(descriptor.container.call, descriptor.container, "get_AllTriggerInfoListData")
    if not all_ok or all_data == nil then return nil end
    local data_items_ok, data_items = pcall(function() return all_data._items end)
    if not data_items_ok or data_items == nil then return nil end
    for _, data in pairs(data_items) do
        if data ~= nil then
            local array_ok, trigger_array = pcall(data.call, data, "get_TriggerInfoList")
            local trigger = array_ok and find_trigger_in_array(trigger_array, descriptor) or nil
            if trigger then return trigger end
            local list_ok, trigger_list = pcall(function() return data._TriggerInfoList end)
            trigger = list_ok and find_trigger_in_list(trigger_list, descriptor) or nil
            if trigger then return trigger end
        end
    end
    return nil
end

local function default_play(descriptor)
    local trigger = resolve_trigger_info(descriptor)
    if trigger == nil then return false, "trigger_info_not_found" end
    local offset_joint_hash = descriptor.offset_joint_hash
    if offset_joint_hash == nil or tonumber(offset_joint_hash) == 0 then
        offset_joint_hash = call(trigger, "get_OffsetJointHash") or 0
        local field_ok, field_value = pcall(function() return trigger._OffsetJointHash end)
        if field_ok and field_value ~= nil then offset_joint_hash = field_value end
    end
    local request = descriptor.container:call(
        CREATE_REQUEST_SIGNATURE,
        trigger, descriptor.source_object, descriptor.target_object,
        offset_joint_hash, false, false, 0, CALLBACK_TYPE_NONE, nil, nil, nil, nil)
    if request == nil then return false, "request_create_failed" end
    pcall(request.add_ref, request)
    local container_set = pcall(function()
        request["<Container>k__BackingField"] = descriptor.container
    end)
    if not container_set then pcall(request.call, request, "set_Container", descriptor.container) end
    local request_id = descriptor.container:call("trigger(soundlib.SoundManager.RequestInfo)", request)
    return true, {
        request_id = request_id and tostring(request_id) or nil,
        playing_id = tostring(call(request, "get_PlayingId") or "0"),
        playing = tostring(call(request, "get_Playing") or false)
    }
end

-- 根据当前场景中的声音容器构造一次性重放描述；调用方负责保证容器仍属于已加载场景。
function Replay.describe_container(container, source_object, target_object, stable_key, metadata)
    if container == nil or type(stable_key) ~= "string" then return nil end
    local event_id, trigger_id = string.match(stable_key, "^(%d+):(%d+)$")
    if not event_id or not trigger_id then return nil end
    local descriptor = {
        event_id = event_id,
        trigger_id = trigger_id,
        container = container,
        source_object = source_object,
        target_object = target_object or source_object,
        offset_joint_hash = type(metadata) == "table" and tonumber(metadata.offsetJointHash) or 0,
        source_path = type(metadata) == "table" and metadata.sourcePath or nil
    }
    if resolve_trigger_info(descriptor) == nil then return nil end
    return descriptor
end

function Replay.new(options)
    options = options or {}
    return {
        descriptors = {},
        unresolved = {},
        descriptor_order = {},
        pending = {},
        playback_states = {},
        active = false,
        submitted = 0,
        failed = 0,
        last_error = nil,
        clock = options.clock or os.clock,
        resolution_retry_seconds = options.resolution_retry_seconds or RESOLUTION_RETRY_INTERVAL,
        resolution_global_interval = options.resolution_global_interval or RESOLUTION_GLOBAL_INTERVAL,
        play_resolution_timeout = options.play_resolution_timeout or PLAY_RESOLUTION_TIMEOUT,
        next_resolution_retry = 0,
        play_descriptor = options.play_descriptor or default_play,
        resolve_descriptor = options.resolve_descriptor
    }
end

-- 为持久收藏提供当前场景解析入口；解析只在页面请求播放或查询可用性时执行。
function Replay.resolve(replay, stable_key, metadata)
    if Replay.has(replay, stable_key) then return replay.descriptors[stable_key] end
    local now = replay.clock()
    local retry_at = replay.unresolved[stable_key]
    -- 失败只短期缓存；对象和触发定义可能晚于 Script Reset 加载。
    -- 多个失败键到期时错开重试，避免页面刷新集中重复扫描所有容器。
    if retry_at and now < retry_at then return nil end
    if now < replay.next_resolution_retry then return nil end
    replay.next_resolution_retry = now + replay.resolution_global_interval
    if type(replay.resolve_descriptor) ~= "function" then return nil end
    local ok, descriptor = pcall(replay.resolve_descriptor, stable_key, metadata)
    if not ok or type(descriptor) ~= "table" then
        replay.unresolved[stable_key] = now + replay.resolution_retry_seconds
        return nil
    end
    replay.descriptors[stable_key] = descriptor
    replay.unresolved[stable_key] = nil
    return descriptor
end

-- 场景容器发生变化后允许之前失败的稳定键重新解析；成功描述无需重复扫描。
function Replay.invalidate_resolution(replay)
    replay.unresolved = {}
    replay.next_resolution_retry = 0
end

function Replay.can_resolve(replay, stable_key, metadata)
    return Replay.resolve(replay, stable_key, metadata) ~= nil
end

-- 页面状态只能读取已缓存描述符，不能在 REFF 轮询期间遍历游戏对象。
function Replay.is_available(replay, stable_key)
    return Replay.has(replay, stable_key)
end

-- 从自然 RequestInfo 保存重放所需对象；Lua 引用由 REFramework 自动维持，队列容量限制其生命周期。
function Replay.capture(replay, request)
    local event_id = call(request, "get_EventId")
    local trigger_id = call(request, "get_TriggerId")
    local container = call(request, "get_Container")
    local source_object = call(request, "get_SrcGameObj")
    local target_object = call(request, "get_TargetGameObj")
    if event_id == nil or trigger_id == nil or container == nil then return false end
    local key = tostring(event_id) .. ":" .. tostring(trigger_id)
    local descriptor = {
        trigger_info = request,
        event_id = tostring(event_id),
        trigger_id = tostring(trigger_id),
        container = container,
        source_object = source_object,
        target_object = target_object,
        offset_joint_hash = call(request, "get_OffsetJointHash") or 0
    }
    local previous = replay.descriptors[key]
    replay.descriptors[key] = descriptor
    replay.unresolved[key] = nil
    -- 同一稳定键重复捕获只更新引用，不重复占用淘汰槽位，避免试听几百次后自我失效。
    if previous == nil then
        replay.descriptor_order[#replay.descriptor_order + 1] = {key = key, value = descriptor}
    else
        for _, entry in ipairs(replay.descriptor_order) do
            if entry.key == key then entry.value = descriptor break end
        end
    end
    while #replay.descriptor_order > MAX_DESCRIPTORS do
        local oldest = table.remove(replay.descriptor_order, 1)
        if replay.descriptors[oldest.key] == oldest.value then replay.descriptors[oldest.key] = nil end
    end
    return true, key
end

function Replay.has(replay, stable_key)
    return replay.descriptors[stable_key] ~= nil
end

function Replay.enqueue(replay, stable_key, metadata)
    if not Replay.has(replay, stable_key) and type(replay.resolve_descriptor) ~= "function" then
        replay.playback_states[stable_key] = {status = "failed", error = "replay_unavailable"}
        return false, "replay_unavailable"
    end
    if #replay.pending >= MAX_PENDING then
        replay.playback_states[stable_key] = {status = "failed", error = "replay_queue_full"}
        return false, "replay_queue_full"
    end
    for _, request in ipairs(replay.pending) do
        if type(request) == "table" and request.stable_key == stable_key then
            replay.playback_states[stable_key] = {status = "trying"}
            return true
        end
    end
    local now = replay.clock()
    replay.pending[#replay.pending + 1] = {
        stable_key = stable_key,
        metadata = metadata,
        expires_at = now + replay.play_resolution_timeout
    }
    replay.playback_states[stable_key] = {status = "trying"}
    return true
end

function Replay.is_active(replay)
    return replay.active == true
end

-- 帧线程每帧最多重放一条；active 守卫覆盖同步触发链，防止试听污染自然捕获。
function Replay.tick(replay)
    if #replay.pending == 0 then return nil end
    local request = replay.pending[1]
    local stable_key = type(request) == "table" and request.stable_key or request
    local metadata = type(request) == "table" and request.metadata or nil
    local descriptor = Replay.resolve(replay, stable_key, metadata)
    if not descriptor then
        local now = replay.clock()
        if type(request) == "table" and now < request.expires_at then
            -- 未加载的来源留在队列中；全局节流保证每帧不会集中遍历多个收藏项。
            table.remove(replay.pending, 1)
            replay.pending[#replay.pending + 1] = request
            return {kind = "waiting", stable_key = stable_key}
        end
        table.remove(replay.pending, 1)
        replay.failed = replay.failed + 1
        replay.last_error = "replay_unavailable"
        replay.playback_states[stable_key] = {status = "failed", error = replay.last_error}
        return {kind = "error", stable_key = stable_key, reason = replay.last_error}
    end
    table.remove(replay.pending, 1)
    replay.active = true
    local ok, played, detail = pcall(replay.play_descriptor, descriptor)
    replay.active = false
    if not ok or played ~= true then
        replay.failed = replay.failed + 1
        replay.last_error = ok and (detail or "replay_failed") or tostring(played)
        replay.playback_states[stable_key] = {status = "failed", error = replay.last_error}
        return {kind = "error", stable_key = stable_key, reason = replay.last_error}
    end
    replay.submitted = replay.submitted + 1
    replay.last_error = nil
    replay.playback_states[stable_key] = {status = "success"}
    return {kind = "submitted", stable_key = stable_key,
        request_id = type(detail) == "table" and detail.request_id or nil,
        playing_id = type(detail) == "table" and detail.playing_id or nil,
        playing = type(detail) == "table" and detail.playing or nil}
end

-- 向 REFF 快照提供稳定键的最近一次播放结果；返回副本避免页面层修改运行时状态。
function Replay.get_playback_state(replay, stable_key)
    local state = replay.playback_states[stable_key]
    if type(state) ~= "table" then return nil end
    return {status = state.status, error = state.error}
end

function Replay.get_status(replay)
    local unresolved_keys = {}
    for key in pairs(replay.unresolved) do unresolved_keys[#unresolved_keys + 1] = key end
    table.sort(unresolved_keys)
    return {
        unresolvedCount = #unresolved_keys,
        unresolvedKeys = #unresolved_keys > 0 and unresolved_keys or nil,
        available = (function()
            local count = 0
            for _ in pairs(replay.descriptors) do count = count + 1 end
            return count
        end)(),
        pending = #replay.pending,
        submitted = replay.submitted,
        failed = replay.failed,
        lastError = replay.last_error
    }
end

return Replay
