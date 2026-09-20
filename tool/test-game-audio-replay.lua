-- 游戏内音频重放队列自检；使用伪 RequestInfo 验证捕获、队列和 active 守卫。

package.path = "reframework/autorun/?.lua;" .. package.path
local Replay = require("VoiceController/VoiceControllerGameAudioReplay")

local active_during_play = false
local replay
replay = Replay.new({play_descriptor = function(descriptor)
    active_during_play = Replay.is_active(replay)
    assert(descriptor.container == "container" and descriptor.offset_joint_hash == 7)
    return true
end})
assert(replay.play_resolution_timeout == 5)
local request = {call = function(_, method)
    local values = {
        get_EventId = 10, get_TriggerId = 20, get_Container = "container",
        get_SrcGameObj = "source", get_TargetGameObj = "target", get_OffsetJointHash = 7
    }
    return values[method]
end}
assert(Replay.capture(replay, request))
assert(Replay.has(replay, "10:20"))
assert(Replay.enqueue(replay, "10:20"))
assert(Replay.get_playback_state(replay, "10:20").status == "trying")
local result = Replay.tick(replay)
assert(result.kind == "submitted" and active_during_play and not Replay.is_active(replay))
assert(Replay.get_playback_state(replay, "10:20").status == "success")
local ok, err = Replay.enqueue(replay, "30:40")
assert(not ok and err == "replay_unavailable")
assert(Replay.get_playback_state(replay, "30:40").status == "failed")

print("VoiceControllerGameAudioReplay tests passed")

local resolve_calls = 0
local resolved = Replay.new({resolve_descriptor = function(key, metadata)
    resolve_calls = resolve_calls + 1
    if key == "30:40" and metadata.category == "player" then
        return {container = "resolved-container", offset_joint_hash = 0}
    end
end, play_descriptor = function(descriptor)
    assert(descriptor.container == "resolved-container")
    return true
end})
assert(Replay.can_resolve(resolved, "30:40", {category = "player"}))
assert(Replay.enqueue(resolved, "30:40", {category = "player"}))
assert(Replay.tick(resolved).kind == "submitted")
assert(resolve_calls == 1)

local unresolved_calls = 0
local unresolved = Replay.new({resolve_descriptor = function()
    unresolved_calls = unresolved_calls + 1
    return nil
end})
assert(not Replay.can_resolve(unresolved, "99:100", {}))
assert(not Replay.can_resolve(unresolved, "99:100", {}))
assert(unresolved_calls == 1)
Replay.invalidate_resolution(unresolved)
assert(not Replay.can_resolve(unresolved, "99:100", {}) and unresolved_calls == 2)

local trigger = {call = function(_, method)
    return ({get_EventId = 30, get_TriggerId = 40})[method]
end}
local trigger_data = {call = function(_, method)
    if method == "get_TriggerInfoList" then return {get_elements = function() return {trigger} end} end
end}
local container = { _TriggerInfoList = {_items = {}}, call = function(_, method)
    if method == "get_AllTriggerInfoListData" then return {_items = {trigger_data}} end
    if method == "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)" then
        return {add_ref = function() end, call = function() end}
    end
    if method == "trigger(soundlib.SoundManager.RequestInfo)" then return 1 end
end}
local direct = Replay.new()
assert(Replay.enqueue(direct, "30:40", {category = "player"}) == false)
assert(Replay.capture(direct, {call = function(_, method)
    return ({get_EventId = 30, get_TriggerId = 40, get_Container = container,
        get_SrcGameObj = "source", get_TargetGameObj = "target", get_OffsetJointHash = 0})[method]
end}))
assert(Replay.enqueue(direct, "30:40"))
assert(Replay.tick(direct).kind == "submitted")

local described = Replay.describe_container(container, "source", "target", "30:40", {
    category = "weapon", offsetJointHash = 9
})
assert(described ~= nil and described.offset_joint_hash == 9)

-- 模拟重载时资源未就绪、随后加载完成；失败缓存必须自动到期且限制集中重试。
local now, ready, attempts = 0, false, 0
local delayed = Replay.new({clock = function() return now end,
    resolve_descriptor = function()
        attempts = attempts + 1
        return ready and {container = container} or nil
    end})
assert(not Replay.can_resolve(delayed, "30:40", {}))
assert(not Replay.can_resolve(delayed, "50:60", {}))
assert(attempts == 1 and not Replay.is_available(delayed, "50:60"))
now = 0.3
assert(not Replay.can_resolve(delayed, "50:60", {}))
assert(Replay.get_status(delayed).unresolvedCount == 2)
ready = true
now = 4.9
assert(not Replay.can_resolve(delayed, "30:40", {}) and attempts == 2)
now = 5
assert(Replay.can_resolve(delayed, "30:40", {}) and attempts == 3)
assert(not Replay.can_resolve(delayed, "50:60", {}) and attempts == 3)
now = 5.3
assert(Replay.can_resolve(delayed, "50:60", {}) and attempts == 4)
assert(Replay.get_status(delayed).unresolvedCount == 0)

-- 新容器到达时可提前解除失败缓存，无须等待该声音自然触发。
ready = false
assert(not Replay.can_resolve(delayed, "70:80", {}))
ready = true
Replay.invalidate_resolution(delayed)
assert(Replay.can_resolve(delayed, "70:80", {}))

-- 点击播放后允许来源延迟加载，并避免同一稳定键重复占用队列。
now, ready, attempts = 0, false, 0
local queued = Replay.new({clock = function() return now end,
    play_resolution_timeout = 12,
    resolve_descriptor = function()
        attempts = attempts + 1
        return ready and {container = "late"} or nil
    end,
    play_descriptor = function(descriptor)
        return descriptor.container == "late"
    end})
assert(Replay.enqueue(queued, "80:90", {}))
assert(Replay.enqueue(queued, "80:90", {}))
assert(Replay.get_status(queued).pending == 1)
assert(Replay.get_playback_state(queued, "80:90").status == "trying")
assert(Replay.tick(queued).kind == "waiting" and attempts == 1)
now = 4
assert(Replay.tick(queued).kind == "waiting" and attempts == 1)
ready, now = true, 5
assert(Replay.tick(queued).kind == "submitted" and attempts == 2)
assert(Replay.get_playback_state(queued, "80:90").status == "success")

local timeout = Replay.new({clock = function() return now end,
    play_resolution_timeout = 1,
    resolve_descriptor = function() return nil end})
now = 0
assert(Replay.enqueue(timeout, "90:100", {}))
assert(Replay.tick(timeout).kind == "waiting")
now = 1
assert(Replay.tick(timeout).kind == "error")
local timeout_state = Replay.get_playback_state(timeout, "90:100")
assert(timeout_state.status == "failed" and timeout_state.error == "replay_unavailable")

-- 执行实际探针中的来源发现函数，模拟 NPC 列表先为空、目标随后生成。
-- 隔离引擎依赖，不加载探针的 Hook、文件写入或帧回调。
local probe_file = assert(io.open("reframework/autorun/VoiceController/VoiceControllerAudioProbe.lua", "rb"))
local probe_source = probe_file:read("*a")
probe_file:close()
local discovery_source = assert(probe_source:match(
    "(local function discover_saved_source_containers.-)\n%-%- 以玩家对象"))
local objects, scans, enumerations = {}, 0, 0
now = 0
local environment = setmetatable({
    os = {clock = function() return now end},
    saved_source_retry_at = {},
    saved_source_names = {npc = {NPC102_00_001 = true}},
    scan_game_object = function() scans = scans + 1 end,
    sdk = {get_managed_singleton = function()
        return {_NpcList = {get_elements = function()
            enumerations = enumerations + 1
            return objects
        end}}
    end}
}, {__index = _G})
local discover = assert(load(discovery_source .. "\nreturn discover_saved_source_containers",
    "persistent-source-discovery", "t", environment))()
discover("npc")
assert(scans == 0 and enumerations == 1)
objects = {{call = function() return {call = function() return "NPC102_00_001" end} end}}
now = 1
discover("npc")
assert(scans == 0 and enumerations == 1)
now = 5
discover("npc")
assert(scans == 1 and enumerations == 2)
-- 坐骑管理器已存在但面部对象尚未生成，也不能永久标记为完成。
local face = nil
environment.saved_source_names.otomo = {}
environment.sdk.get_managed_singleton = function()
    return {call = function(_, method)
        if method == "getMasterOtomoManagedControl" then
            return {call = function() return face end}
        end
    end}
end
discover("otomo")
assert(scans == 1)
face = {call = function() return "Otomo_00" end}
now = 6
discover("otomo")
assert(scans == 1)
now = 10
discover("otomo")
assert(scans == 2)
print("Persistent replay delayed-loading regressions passed")
