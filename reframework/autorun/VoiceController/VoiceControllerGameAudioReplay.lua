-- VoiceController 游戏内音频重放队列。
-- Hook 只登记本会话请求引用；REFF 只入队稳定键；帧线程创建新 RequestInfo 并触发，人工重放期间必须屏蔽自然捕获和规则匹配。

local Replay = {}

local MAX_DESCRIPTORS = 512
local MAX_PENDING = 16
local CALLBACK_DURATION_AND_END = 9
local CREATE_REQUEST_SIGNATURE = "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)"

local function call(object, method, ...)
    if object == nil then return nil end
    local ok, result = pcall(object.call, object, method, ...)
    return ok and result or nil
end

-- 帧线程从容器的稳定触发定义中按双 ID 定位条目；RequestInfo 会被游戏复用，不能作为长期重放模板。
local function resolve_trigger_info(descriptor)
    local ok, list = pcall(function() return descriptor.container._TriggerInfoList end)
    if not ok or list == nil then return nil end
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

local function default_play(descriptor)
    local trigger = resolve_trigger_info(descriptor)
    if trigger == nil then return false, "trigger_info_not_found" end
    local request = descriptor.container:call(
        CREATE_REQUEST_SIGNATURE,
        trigger, descriptor.source_object, descriptor.target_object,
        descriptor.offset_joint_hash, false, false, 0, CALLBACK_DURATION_AND_END, nil, nil, nil, nil)
    if request == nil then return false, "request_create_failed" end
    pcall(request.add_ref, request)
    request:call("set_Container", descriptor.container)
    local request_id = descriptor.container:call("trigger(soundlib.SoundManager.RequestInfo)", request)
    return true, {
        request_id = request_id and tostring(request_id) or nil,
        playing_id = tostring(call(request, "get_PlayingId") or "0")
    }
end

function Replay.new(options)
    options = options or {}
    return {
        descriptors = {},
        descriptor_order = {},
        pending = {},
        active = false,
        submitted = 0,
        failed = 0,
        last_error = nil,
        play_descriptor = options.play_descriptor or default_play,
        resolve_descriptor = options.resolve_descriptor
    }
end

-- 为持久收藏提供当前场景解析入口；解析只在页面请求播放或查询可用性时执行。
function Replay.resolve(replay, stable_key, metadata)
    if Replay.has(replay, stable_key) then return replay.descriptors[stable_key] end
    if type(replay.resolve_descriptor) ~= "function" then return nil end
    local ok, descriptor = pcall(replay.resolve_descriptor, stable_key, metadata)
    if not ok or type(descriptor) ~= "table" then return nil end
    replay.descriptors[stable_key] = descriptor
    return descriptor
end

function Replay.can_resolve(replay, stable_key, metadata)
    return Replay.resolve(replay, stable_key, metadata) ~= nil
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
        return false, "replay_unavailable"
    end
    if #replay.pending >= MAX_PENDING then return false, "replay_queue_full" end
    replay.pending[#replay.pending + 1] = {stable_key = stable_key, metadata = metadata}
    return true
end

function Replay.is_active(replay)
    return replay.active == true
end

-- 帧线程每帧最多重放一条；active 守卫覆盖同步触发链，防止试听污染自然捕获。
function Replay.tick(replay)
    if #replay.pending == 0 then return nil end
    local request = table.remove(replay.pending, 1)
    local stable_key = type(request) == "table" and request.stable_key or request
    local metadata = type(request) == "table" and request.metadata or nil
    local descriptor = Replay.resolve(replay, stable_key, metadata)
    if not descriptor then
        replay.failed = replay.failed + 1
        replay.last_error = "replay_unavailable"
        return {kind = "error", stable_key = stable_key, reason = replay.last_error}
    end
    replay.active = true
    local ok, played, detail = pcall(replay.play_descriptor, descriptor)
    replay.active = false
    if not ok or played ~= true then
        replay.failed = replay.failed + 1
        replay.last_error = ok and (detail or "replay_failed") or tostring(played)
        return {kind = "error", stable_key = stable_key, reason = replay.last_error}
    end
    replay.submitted = replay.submitted + 1
    replay.last_error = nil
    return {kind = "submitted", stable_key = stable_key,
        request_id = type(detail) == "table" and detail.request_id or nil,
        playing_id = type(detail) == "table" and detail.playing_id or nil}
end

function Replay.get_status(replay)
    return {
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
