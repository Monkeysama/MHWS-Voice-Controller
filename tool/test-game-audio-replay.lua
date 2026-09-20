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
local result = Replay.tick(replay)
assert(result.kind == "submitted" and active_during_play and not Replay.is_active(replay))
local ok, err = Replay.enqueue(replay, "30:40")
assert(not ok and err == "replay_unavailable")

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
