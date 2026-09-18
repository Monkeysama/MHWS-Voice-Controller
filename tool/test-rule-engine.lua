-- 阶段三规则引擎的纯 Lua 自检；不连接游戏、不访问 REFAudio 文件。

package.path = "reframework/autorun/?.lua;" .. package.path

local RuleEngine = require("VoiceController/VoiceControllerRuleEngine")

local function compile(overrides)
    local config = {
        schemaVersion = 1,
        enabled = true,
        eventId = "3499935827",
        triggerId = "114982064",
        mode = "overlay",
        replaceStrategy = "stop_playing_id",
        file = "VoiceController/PlayerVoice/Audio/replacement.ogg",
        volume = 0.8,
        speed = 1.1,
        maxDurationMs = 1500,
        cooldownMs = 200,
        fallbackToOriginal = true
    }
    for key, value in pairs(overrides or {}) do config[key] = value end
    return RuleEngine.compile(config)
end

local valid = compile()
assert(valid.valid and valid.enabled)
assert(valid.file == "VoiceController\\PlayerVoice\\Audio\\replacement.ogg")
assert(RuleEngine.match(valid, 3499935827, 114982064))
assert(not RuleEngine.match(valid, 3499935827, 1))

local accepted, reason = RuleEngine.accept(valid, 1000)
assert(accepted and reason == "overlay")
accepted, reason = RuleEngine.accept(valid, 1100)
assert(not accepted and reason == "cooldown")
accepted, reason = RuleEngine.accept(valid, 1200)
assert(accepted and reason == "overlay")

local traversal = compile({file = "VoiceController\\..\\REFAudio\\bad.wav"})
assert(not traversal.valid and not traversal.enabled)
local absolute = compile({file = "C:\\temp\\bad.wav"})
assert(not absolute.valid and not absolute.enabled)
local replace = compile({mode = "replace"})
assert(replace.valid and replace.enabled and replace.mode == "replace")
local ineffective_replace = compile({mode = "replace", replaceStrategy = "remove_queued_request"})
assert(not ineffective_replace.valid and ineffective_replace.mode == "observe")
local ineffective_mute = compile({mode = "replace", replaceStrategy = "mute_request"})
assert(not ineffective_mute.valid and ineffective_mute.mode == "observe")
local skip_original = compile({mode = "replace", replaceStrategy = "skip_original"})
assert(skip_original.valid and skip_original.enabled and skip_original.mode == "replace")
local no_fallback = compile({fallbackToOriginal = false})
assert(not no_fallback.valid and not no_fallback.enabled)

print("VoiceControllerRuleEngine tests passed")
