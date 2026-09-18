-- VoiceController v1/v2 替换运行时纯 Lua自检；预检与音频队列均使用内存替身。

package.path = "reframework/autorun/?.lua;" .. package.path

local Runtime = require("VoiceController/VoiceControllerReplacementRuntime")

local v2 = Runtime.compile({
    schemaVersion = 2,
    enabled = true,
    mode = "replace",
    replaceStrategy = "skip_original",
    maxDurationMs = 50,
    maxConcurrent = 1,
    groups = {{
        id = "player_voice",
        rules = {{
            id = "target",
            eventId = "3499935827",
            triggerId = "114982064",
            candidates = {
                {file = "VoiceController/PlayerVoice/Audio/a.wav", weight = 1},
                {file = "VoiceController/PlayerVoice/Audio/b.wav", weight = 3}
            }
        }}
    }}
})
assert(v2.valid and v2.enabled and Runtime.summary(v2).ruleCount == 1)
assert(Runtime.requires_preflight(v2))
assert(Runtime.refresh_preflight(v2, function(path)
    return path:match("[ab]%.wav$") ~= nil, nil
end))

local queued = {}
local first = Runtime.dispatch(v2, 3499935827, 114982064, 1000, 0.9, function(spec)
    queued[#queued + 1] = spec
    return true
end)
assert(first.matched and first.queued and first.reason == "replace")
assert(first.candidate.file:match("b%.wav$") and #queued == 1)
local blocked = Runtime.dispatch(v2, 3499935827, 114982064, 1100, 0, function() return true end)
assert(blocked.matched and blocked.reason == "concurrency")
assert(Runtime.expire(v2, 1050) == 1)

local missing = Runtime.compile({
    schemaVersion = 2,
    enabled = true,
    mode = "replace",
    replaceStrategy = "skip_original",
    groups = {{id = "g", rules = {{
        eventId = "1", triggerId = "2",
        candidates = {{file = "VoiceController/Audio/missing.wav"}}
    }}}}
})
Runtime.refresh_preflight(missing, function() return false, "audio_file_missing" end)
local fallback = Runtime.dispatch(missing, 1, 2, 0, 0, function() return true end)
assert(fallback.matched and not fallback.queued and fallback.reason == "fallback_audio_file_missing")
assert(fallback.rule.active_count == 0)

local v1 = Runtime.compile({
    schemaVersion = 1,
    enabled = true,
    eventId = "7",
    triggerId = "8",
    mode = "overlay",
    replaceStrategy = "skip_original",
    file = "VoiceController/Audio/legacy.ogg",
    cooldownMs = 0,
    fallbackToOriginal = true
})
assert(Runtime.requires_preflight(v1))
Runtime.refresh_preflight(v1, function() return true end)
local legacy = Runtime.dispatch(v1, 7, 8, 0, 0, function(spec)
    return spec.file:match("legacy%.ogg$") ~= nil
end)
assert(legacy.matched and legacy.queued and legacy.reason == "overlay")
assert(not Runtime.dispatch(v1, 1, 2, 0, 0, function() return true end).matched)

local observe = Runtime.compile({
    schemaVersion = 1,
    enabled = true,
    eventId = "9",
    triggerId = "10",
    mode = "observe",
    fallbackToOriginal = true
})
assert(not Runtime.requires_preflight(observe))

print("VoiceControllerReplacementRuntime tests passed")
