-- VoiceController v2 分组规则集纯 Lua 自检；不连接游戏，不访问文件或音频后端。

package.path = "reframework/autorun/?.lua;" .. package.path

local RuleSet = require("VoiceController/VoiceControllerRuleSet")

local function config(overrides)
    local value = {
        schemaVersion = 2,
        enabled = true,
        mode = "replace",
        replaceStrategy = "skip_original",
        cooldownMs = 100,
        maxConcurrent = 2,
        maxDurationMs = 50,
        groups = {
            {
                id = "player_voice",
                enabled = true,
                rules = {
                    {
                        id = "greeting",
                        eventId = "3499935827",
                        triggerId = "114982064",
                        candidates = {
                            {file = "VoiceController/PlayerVoice/Audio/a.wav", weight = 1},
                            {file = "VoiceController/PlayerVoice/Audio/b.ogg", weight = 3}
                        }
                    }
                }
            }
        }
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local compiled = RuleSet.compile(config())
assert(compiled.valid and compiled.enabled)
local rule = RuleSet.find(compiled, 3499935827, 114982064)
assert(rule and rule.stable_key == "3499935827:114982064")
assert(RuleSet.select_candidate(rule, 0).file:match("a%.wav$"))
assert(RuleSet.select_candidate(rule, 0.99).file:match("b%.ogg$"))

local token, reason = RuleSet.acquire(rule, 1000, 0.5)
assert(token and reason == "accepted" and rule.active_count == 1)
local second = RuleSet.acquire(rule, 1050, 0.5)
assert(second == nil)
local third = RuleSet.acquire(rule, 1100, 0.5)
assert(third and rule.active_count == 2)
assert(RuleSet.acquire(rule, 1200, 0.5) == nil)
assert(RuleSet.release(token))
assert(RuleSet.release(third))
assert(rule.active_count == 0)
assert(not RuleSet.release(third))

local expiring, expiring_reason = RuleSet.acquire(rule, 2000, 0.5)
assert(expiring and expiring_reason == "accepted" and rule.active_count == 1)
assert(RuleSet.expire(rule, 2049) == 0 and rule.active_count == 1)
assert(RuleSet.expire(rule, 2050) == 1 and rule.active_count == 0)

local duplicate = config()
duplicate.groups[1].rules[1].id = "duplicate"
local duplicate_group = {
    id = "other",
    rules = {{
        eventId = "3499935827", triggerId = "114982064",
        candidates = {{file = "VoiceController/PlayerVoice/Audio/c.wav"}}
    }}
}
duplicate.groups[2] = duplicate_group
local invalid = RuleSet.compile(duplicate)
assert(invalid.valid and invalid.enabled and #invalid.warnings == 1)
assert(string.find(invalid.warnings[1], "duplicate_stable_key_across_groups", 1, true))

local unsafe = config()
unsafe.groups[1].rules[1].candidates[1].file = "VoiceController/../bad.wav"
local unsafe_compiled = RuleSet.compile(unsafe)
assert(not unsafe_compiled.valid)

print("VoiceControllerRuleSet tests passed")
