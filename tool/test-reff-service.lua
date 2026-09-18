-- VoiceController REFF 服务纯 Lua 自检；SDK、原生桥接和 JSON 均使用内存替身。

package.path = "reframework/autorun/?.lua;" .. package.path

local ConfigManager = require("VoiceController/VoiceControllerConfigManager")
local Service = require("VoiceController/VoiceControllerREFF")

local catalog = {errors = {}, files = {
    {file = "VoiceController\\Audio\\a.wav"},
    {file = "VoiceController\\Audio\\b.ogg"}
}}
local manager = assert(ConfigManager.new({
    schemaVersion = 2,
    enabled = true,
    mode = "observe",
    replaceStrategy = "skip_original",
    groups = {{id = "voice", enabled = true, rules = {{
        id = "one", eventId = "1", triggerId = "2",
        candidates = {{file = "VoiceController\\Audio\\a.wav"}}
    }}}}
}, catalog))

local registered = nil
local emitted = nil
local sdk = {
    register = function(plugin_id, handlers, native)
        assert(plugin_id == "voice-controller")
        registered = handlers
        return {
            emit = function(event_name, payload)
                assert(event_name == "voice-controller.changed")
                emitted = payload
                return true
            end
        }
    end
}
local native = {
    is_ready = function() return true end,
    emit = function() return true end
}
local saved = false
local tested = false
local saved_events = {}
local played = false
-- 分组文件夹替身：文件夹就是分组，扫描结果只提供元数据与占用关系。
local folder_groups = {{
    folder = "测试分组", name = "测试分组", version = "1.0.0", author = "tester",
    audio_directory = "VoiceController\\Groups\\测试分组\\Audio",
    has_manifest = true, rules = {}, warnings = {}
}}
local conflicts = {{stableKey = "1:2", winner = nil, losers = {}}}
local recent_events = {{eventId = "3", triggerId = "4", stableKey = "3:4", category = "voice"}}
for index = 1, 121 do
    recent_events[#recent_events + 1] = {
        eventId = tostring(index + 10), triggerId = "1", stableKey = tostring(index + 10) .. ":1", category = "unknown"
    }
end
local handle = assert(Service.register({
    get_status = function() return {mode = "observe", totalCaptured = 1} end,
    get_recent_events = function()
        return recent_events
    end,
    get_saved_events = function() return saved_events end,
    get_saved_event = function(stable_key)
        for _, event in ipairs(saved_events) do
            if event.stableKey == stable_key then return event end
        end
    end,
    save_event = function(stable_key)
        saved_events[1] = {eventId = "3", triggerId = "4", stableKey = stable_key}
        return true
    end,
    remove_saved_event = function(stable_key)
        assert(stable_key == "3:4")
        saved_events = {}
        return true
    end,
    play_event = function(stable_key)
        played = stable_key == "3:4"
        return played
    end,
    ensure_group_directory = function(path)
        return path == "VoiceController\\Groups\\Test Group\\Audio"
    end,
    get_catalog = function() return catalog end,
    -- 与探测器的 get_group_folders 语义一致：只给元数据，规则体在 config.groups 里。
    get_group_folders = function()
        local result = {}
        for _, entry in ipairs(folder_groups) do
            result[#result + 1] = {
                folder = entry.folder, name = entry.name, version = entry.version,
                author = entry.author, audioDirectory = entry.audio_directory,
                hasManifest = entry.has_manifest == true, registered = false,
                writable = false,   -- 非 ASCII 目录名：能播放但不能回写 group.json
                ruleCount = #entry.rules, warnings = nil
            }
        end
        return result
    end,
    get_conflicts = function() return conflicts end,
    get_group_rejects = function() return {} end,
    get_unwritable_folders = function()
        return {{id = "group", folder = "测试分组"}}
    end,
    get_config_manager = function() return manager end,
    get_config_manager_error = function() return nil end,
    save_config = function(value)
        saved = value == manager
        if saved then manager.dirty = false end
        return saved
    end,
    test_candidate = function(value, group_id, rule_id, candidate_index)
        tested = value == manager and group_id == "voice" and rule_id == "one"
            and candidate_index == 1
        return tested
    end
}, {native = native, sdk = sdk, json = {dump_string = function() return "{}" end}}))
assert(handle and registered)

local state = registered.methods["voice-controller.get-state"]()
assert(state.editor.ready and #state.events == 122 and state.events[1].stableKey == "3:4"
    and state.config.groups[1].id == "voice")
state = registered.methods["voice-controller.save-event"]({stableKey = "3:4"})
assert(#state.savedEvents == 1 and emitted ~= nil)
state = registered.methods["voice-controller.play-event"]({stableKey = "3:4"})
assert(played and #state.savedEvents == 1)
state = registered.methods["voice-controller.add-group"]({name = "Test Group"})
assert(state.config.groups[2].id == "test-group")
state = registered.methods["voice-controller.update-rule"]({
    groupId = "voice", ruleId = "one", enabled = false, cooldownMs = 200
})
assert(state.config.groups[1].rules[1].enabled == false)
local revision_before_test = state.revision
state = registered.methods["voice-controller.test-candidate"]({
    groupId = "voice", ruleId = "one", candidateIndex = 1
})
assert(tested and state.revision == revision_before_test and state.editor.dirty)
state = registered.methods["voice-controller.remove-saved-event"]({stableKey = "3:4"})
assert(#state.savedEvents == 0)
state = registered.methods["voice-controller.save"]()
assert(saved and state.editor.dirty == false)

-- 分组文件夹：只推元数据与占用关系，规则体在 config.groups 里
assert(#state.groupFolders == 1 and state.groupFolders[1].folder == "测试分组")
assert(state.groupFolders[1].hasManifest == true and state.groupFolders[1].ruleCount == 0)
assert(state.groupFolders[1].writable == false, "非 ASCII 目录名不可回写清单")
assert(#state.conflicts == 1 and #state.folderRejects == 0)
-- 非 ASCII 目录名单独推一份清单，界面据此给出“无法写入 group.json”的提示
assert(#state.unwritableFolders == 1 and state.unwritableFolders[1].folder == "测试分组")

print("VoiceControllerREFF tests passed")
