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

local resolved = Replay.new({resolve_descriptor = function(key, metadata)
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
