-- VoiceController 配置管理器纯 Lua 自检；目录、JSON 和文件替换均由内存替身提供。

package.path = "reframework/autorun/?.lua;" .. package.path

local Manager = require("VoiceController/VoiceControllerConfigManager")
local GroupStore = require("VoiceController/VoiceControllerGroupStore")

local function base_config()
    return {
        schemaVersion = 2,
        enabled = true,
        mode = "observe",
        replaceStrategy = "skip_original",
        maxConcurrent = 2,
        groups = {{
            id = "player_voice",
            enabled = true,
            rules = {{
                id = "target_voice",
                eventId = "3499935827",
                triggerId = "114982064",
                candidates = {{
                    file = "VoiceController\\PlayerVoice\\Audio\\a.wav",
                    weight = 1,
                    volume = 0.2,
                    speed = 1,
                    maxDurationMs = 700
                }}
            }}
        }}
    }
end

local catalog = {
    errors = {},
    files = {
        {file = "VoiceController\\PlayerVoice\\Audio\\a.wav"},
        {file = "VoiceController\\PlayerVoice\\Audio\\b.ogg"},
        {file = "VoiceController\\Monster\\roar.mp3"},
        {file = "VoiceController\\Groups\\My Voices\\Audio\\custom.wav"},
        {file = "VoiceController\\Groups\\group\\Audio\\custom.wav"},
        {file = "VoiceController\\Groups\\group-2\\Audio\\custom.wav"}
    }
}

local manager, errors = Manager.new(base_config(), catalog)
assert(manager and errors == nil and manager.config.mode == "observe")
assert(not manager.dirty and manager.revision == 0)
assert(#manager.removed_groups == 0)
local catalog_updated, catalog_errors = Manager.set_catalog(manager, catalog)
assert(catalog_updated and catalog_errors == nil)

local manager_without_catalog = assert(Manager.new(base_config()))
assert(not Manager.create_rule_from_event(manager_without_catalog,
    {eventId = "100", triggerId = "200"},
    {file = "VoiceController\\PlayerVoice\\Audio\\a.wav"}))
assert(not Manager.save(manager_without_catalog, "VoiceController\\replacement.json", {}))
assert(not Manager.set_catalog(manager_without_catalog, {files = {}, errors = {{code = "scan_failed"}}}))

local ok, result = Manager.create_rule_from_event(manager, {
    eventId = "100", triggerId = "200", origin = "SoundManager.postRequestInfo"
}, {
    group_id = "player_voice",
    rule_id = "captured",
    file = "voicecontroller/playerVoice/audio/B.OGG",
    volume = 0.5
})
assert(ok and result == "captured")
assert(manager.dirty and manager.revision == 1)
local snapshot = Manager.snapshot(manager)
assert(snapshot.mode == "observe")
assert(snapshot.groups[1].rules[2].enabled == false)
assert(snapshot.groups[1].rules[2].mode == "observe")
assert(snapshot.groups[1].rules[2].candidates[1].file
    == "VoiceController\\PlayerVoice\\Audio\\b.ogg")

ok, errors = Manager.create_rule_from_event(manager, {eventId = "100", triggerId = "200"}, {
    file = "VoiceController\\Monster\\roar.mp3"
})
assert(not ok and errors[1] == "duplicate_stable_key.100:200")

ok, result = Manager.add_candidate(manager, "player_voice", "captured",
    "VoiceController\\Monster\\roar.mp3", {weight = 3, speed = 1.2})
assert(ok and result == 2)
ok, errors = Manager.add_candidate(manager, "player_voice", "captured",
    "VoiceController\\MONSTER\\ROAR.MP3")
assert(not ok and errors[1] == "duplicate_candidate")

ok = Manager.update_candidate(manager, "player_voice", "captured", 2, {
    weight = 4, volume = 0.7, speed = 1.1, max_duration_ms = 1200
})
assert(ok)
snapshot = Manager.snapshot(manager)
local updated = snapshot.groups[1].rules[2].candidates[2]
assert(updated.weight == 4 and updated.volume == 0.7 and updated.speed == 1.1)
assert(updated.maxDurationMs == 1200)

local revision = manager.revision
ok, errors = Manager.update_candidate(manager, "player_voice", "captured", 2, {weight = 0})
assert(not ok and manager.revision == revision)
assert(string.find(table.concat(errors, ","), "invalid_weight", 1, true))
ok, errors = Manager.update_candidate(manager, "player_voice", "captured", 2, {
    file = "VoiceController\\missing.wav"
})
assert(not ok and errors[1] == "file_not_in_catalog")

ok = Manager.remove_candidate(manager, "player_voice", "captured", 2)
assert(ok)
ok, errors = Manager.remove_candidate(manager, "player_voice", "captured", 1)
assert(not ok and errors[1] == "last_candidate")

local resolved, playback = Manager.get_candidate_playback_spec(manager, "player_voice", "captured", 1)
assert(resolved and playback.source == "test")
assert(playback.volume == 0.5 and playback.speed == 1 and playback.max_duration_ms == 0)
assert(manager.revision > 0 and manager.dirty)
resolved, errors = Manager.get_candidate_playback_spec(manager, "player_voice", "captured", 99)
assert(not resolved and errors[1] == "candidate_not_found")

ok = Manager.update_rule(manager, "player_voice", "captured", {
    enabled = true, mode = "replace", replace_strategy = "skip_original",
    cooldown_ms = 250, max_concurrent = 3
})
assert(ok)
snapshot = Manager.snapshot(manager)
local rule = snapshot.groups[1].rules[2]
assert(rule.enabled and rule.mode == "replace" and rule.cooldownMs == 250)
assert(rule.maxConcurrent == 3 and snapshot.mode == "observe")
assert(rule.replaceStrategy == "skip_original")

local invalid_config = base_config()
invalid_config.groups[1].rules[2] = {
    id = "duplicate", eventId = "3499935827", triggerId = "114982064",
    candidates = {{file = "VoiceController\\PlayerVoice\\Audio\\a.wav"}}
}
assert(Manager.new(invalid_config, catalog) == nil)
assert(Manager.new({schemaVersion = 2, groups = "invalid"}, catalog) == nil)

-- 权威目录快照必须剔除 replacement.json 中已经没有实体文件夹的旧分组。
local stale_config = {
    schemaVersion = 2, enabled = true, mode = "observe",
    groups = {
        {id = "player_voice", name = "Player Voice", enabled = true,
         audioDirectory = "VoiceController\\Groups\\player-voice\\Audio", rules = {_empty = true}},
        {id = "kept", name = "保留", enabled = true,
         audioDirectory = "VoiceController\\Groups\\测试中文分组\\Audio", rules = {_empty = true}}
    }
}
local reconciled = assert(Manager.new(stale_config, catalog, {{
    folder = "测试中文分组", name = "测试中文分组",
    audio_directory = "VoiceController\\Groups\\测试中文分组\\Audio",
    rules = {}, warnings = {}, has_manifest = true
}}))
assert(#reconciled.config.groups == 1 and reconciled.config.groups[1].id == "kept")
assert(#reconciled.removed_groups == 1)
assert(reconciled.removed_groups[1].id == "player_voice")
assert(reconciled.removed_groups[1].folder == "player-voice")
local rejected_but_present = assert(Manager.new(stale_config, catalog, {}, {"player-voice"}))
assert(#rejected_but_present.config.groups == 1)
assert(rejected_but_present.config.groups[1].id == "player_voice")
assert(#rejected_but_present.removed_groups == 1)
assert(rejected_but_present.removed_groups[1].id == "kept")
-- 尚未扫描时不得清理；完成扫描后的空表才表示 Groups 目录确实为空。
assert(#assert(Manager.new(stale_config, catalog, nil)).config.groups == 2)
assert(#assert(Manager.new(stale_config, catalog, {})).config.groups == 0)

local files = {}
local function encode(value)
    assert(value.mode == "observe")
    return "serialized-config"
end
local function decode(value)
    assert(value == "serialized-config")
    return Manager.snapshot(manager)
end
local file_api = {
    encode = encode,
    decode = decode,
    read = function(path) return files[path] end,
    write = function(path, value) files[path] = value return true end,
    exists = function(path) return files[path] ~= nil end,
    rename = function(source, target)
        if files[source] == nil then return false, "missing_source" end
        files[target] = files[source]
        files[source] = nil
        return true
    end,
    remove = function(path) files[path] = nil return true end
}
files["VoiceController\\replacement.json"] = "old-config"
ok, errors = Manager.save(manager, "VoiceController\\replacement.json", file_api)
assert(ok and errors == nil)
assert(files["VoiceController\\replacement.json"] == "serialized-config")
assert(files["VoiceController\\replacement.json.tmp"] == nil)
assert(files["VoiceController\\replacement.json.bak"] == nil)
assert(not manager.dirty and manager.last_saved_revision == manager.revision)

local rollback_files = {[
    "VoiceController\\replacement.json"] = "old-config"
}
local rename_count = 0
local rollback_api = {
    encode = encode,
    decode = decode,
    read = function(path) return rollback_files[path] end,
    write = function(path, value) rollback_files[path] = value return true end,
    exists = function(path) return rollback_files[path] ~= nil end,
    rename = function(source, target)
        rename_count = rename_count + 1
        if rename_count == 2 then return false, "locked" end
        if rollback_files[source] == nil then return false, "missing_source" end
        rollback_files[target] = rollback_files[source]
        rollback_files[source] = nil
        return true
    end,
    remove = function(path) rollback_files[path] = nil return true end
}
ok, errors = Manager.save(manager, "VoiceController\\replacement.json", rollback_api)
assert(not ok and string.find(errors, "replace_failed", 1, true))
assert(rollback_files["VoiceController\\replacement.json"] == "old-config")

local corrupt_files = {}
local corrupt_api = {
    encode = encode,
    decode = decode,
    read = function(path) return corrupt_files[path] end,
    write = function(path, value) corrupt_files[path] = value return true end,
    exists = function(path) return corrupt_files[path] ~= nil end,
    replace = function(source, target)
        corrupt_files[source] = nil
        corrupt_files[target] = "corrupted"
        return true
    end,
    remove = function(path) corrupt_files[path] = nil return true end
}
ok, errors = Manager.save(manager, "VoiceController\\replacement.json", corrupt_api)
assert(not ok and errors == "target_verify_failed")

local direct_files = {[
    "VoiceController\\replacement.json"] = "old-config"
}
local direct_api = {
    encode = function() return "new-config" end,
    decode = function(value)
        assert(value == "old-config" or value == "new-config")
        return Manager.snapshot(manager)
    end,
    read = function(path) return direct_files[path] end,
    write = function(path, value) direct_files[path] = value return true end,
    exists = function(path) return direct_files[path] ~= nil end
}
ok, errors = Manager.save(manager, "VoiceController\\replacement.json", direct_api)
assert(ok and errors == nil)
assert(direct_files["VoiceController\\replacement.json"] == "new-config")
assert(direct_files["VoiceController\\replacement.json.tmp"] == "new-config")
assert(direct_files["VoiceController\\replacement.json.bak"] == "old-config")

direct_files["VoiceController\\replacement.json"] = "old-config"
local target_write_count = 0
direct_api.write = function(path, value)
    if path == "VoiceController\\replacement.json" then
        target_write_count = target_write_count + 1
        direct_files[path] = target_write_count == 1 and "corrupted" or value
    else
        direct_files[path] = value
    end
    return true
end
ok, errors = Manager.save(manager, "VoiceController\\replacement.json", direct_api)
assert(not ok and errors == "target_verify_failed")
assert(direct_files["VoiceController\\replacement.json"] == "old-config")

assert(not Manager.save(manager, "..\\replacement.json", file_api))
assert(Manager.remove_rule(manager, "player_voice", "captured"))

ok = Manager.create_rule_from_event(manager, {eventId = "300", triggerId = "400"}, {
    group_id = "temporary_group",
    file = "VoiceController\\PlayerVoice\\Audio\\a.wav"
})
assert(ok)
assert(Manager.remove_rule(manager, "temporary_group", "event_300_400"))
snapshot = Manager.snapshot(manager)
local temporary_group = snapshot.groups[#snapshot.groups]
assert(temporary_group.id == "temporary_group" and temporary_group.rules._empty == true)

ok, result = Manager.add_group(manager, "My Voices")
assert(ok and result == "my-voices")
snapshot = Manager.snapshot(manager)
local custom_group = snapshot.groups[#snapshot.groups]
assert(custom_group.name == "My Voices")
assert(custom_group.audioDirectory == "VoiceController\\Groups\\My Voices\\Audio")
ok, result = Manager.add_rule_from_saved_event(manager, custom_group.id,
    {eventId = "500", triggerId = "600"},
    "VoiceController\\Groups\\My Voices\\Audio\\custom.wav")
assert(ok and result == "event_500_600")
ok, errors = Manager.add_rule_from_saved_event(manager, custom_group.id,
    {eventId = "501", triggerId = "601"}, "VoiceController\\PlayerVoice\\Audio\\a.wav")
assert(not ok and errors[1] == "outside_group_audio")
assert(Manager.update_group(manager, custom_group.id, {name = "Combat Voices", enabled = false}))
snapshot = Manager.snapshot(manager)
custom_group = snapshot.groups[#snapshot.groups]
assert(custom_group.name == "Combat Voices" and custom_group.enabled == false)
assert(Manager.remove_group(manager, custom_group.id))

-- 中文显示名：显示名保留中文，磁盘目录名必须是纯 ASCII —— REFramework 的 Lua 文件 API 按本机代码页
-- 解释路径字符串，中文目录名会被写到另一个名字上（测试 → 娴嬭瘯），并且读到的是同一批错误名字。
ok, result = Manager.add_group(manager, "测试分组")
assert(ok and result == "group")
snapshot = Manager.snapshot(manager)
local unicode_group = snapshot.groups[#snapshot.groups]
assert(unicode_group.name == "测试分组")
assert(unicode_group.audioDirectory == "VoiceController\\Groups\\测试分组\\Audio",
    unicode_group.audioDirectory)
-- 显示名重复时目录名自动让路，不会因为中文折叠而抢占已有目录
ok, result = Manager.add_group(manager, "测试分组")
assert(ok and result == "group_2")
snapshot = Manager.snapshot(manager)
assert(snapshot.groups[#snapshot.groups].audioDirectory
    == "VoiceController\\Groups\\测试分组-2\\Audio")
assert(not Manager.add_group(manager, "CON"))
assert(not Manager.add_group(manager, "invalid/name"))

-- 保存时跳过非 ASCII 目录的清单回写：绝不生成乱码目录，但 replacement.json 照常写出并给出告警
local unicode_files = {}
local unicode_writes = {}
local unicode_manager
local unicode_api = {
    encode = function(value)
        if value.schemaVersion == 1 then return "manifest:" .. tostring(value.name) end
        return "unicode-config"
    end,
    decode = function(value)
        if value == "unicode-config" then return Manager.snapshot(unicode_manager) end
        return nil
    end,
    read = function(path) return unicode_files[path] end,
    write = function(path, value)
        unicode_files[path] = value
        unicode_writes[#unicode_writes + 1] = path
        return true
    end,
    exists = function(path) return unicode_files[path] ~= nil end,
    replace = function(source, target)
        unicode_files[target] = unicode_files[source]
        unicode_files[source] = nil
        return true
    end,
    remove = function(path) unicode_files[path] = nil return true end
}
local unicode_catalog = {errors = {}, files = {
    {file = "VoiceController\\Groups\\测试\\Audio\\hit.wav"},
    {file = "VoiceController\\Groups\\pack\\Audio\\hit.wav"}
}}
unicode_manager = assert(Manager.new({
    schemaVersion = 2, enabled = true, mode = "observe",
    groups = {
        {id = "group", name = "测试", enabled = false,
         audioDirectory = "VoiceController\\Groups\\测试\\Audio",
         rules = {{id = "r1", eventId = "3499935827", triggerId = "114982064",
             candidates = {{file = "VoiceController\\Groups\\测试\\Audio\\hit.wav"}}}}},
        {id = "pack", name = "Pack", enabled = false,
         audioDirectory = "VoiceController\\Groups\\pack\\Audio",
         rules = {{id = "r2", eventId = "3499935827", triggerId = "114982065",
             candidates = {{file = "VoiceController\\Groups\\pack\\Audio\\hit.wav"}}}}}
    }
}, unicode_catalog))
assert(Manager.save(unicode_manager, "VoiceController\\replacement.json", unicode_api))
assert(unicode_files["VoiceController\\replacement.json"] == "unicode-config", "配置本身必须写出")
for _, path in ipairs(unicode_writes) do
    -- UTF-8 文件桥允许真实中文路径；ASCII 路径仍保持原样。
end
assert(#unicode_manager.manifest_skipped == 1)
assert(unicode_manager.manifest_skipped[1].id == "group")
assert(unicode_files["VoiceController\\Groups\\pack\\group.json"] == "manifest:Pack",
    "ASCII 目录照常回写清单")
local unicode_warnings = Manager.warnings(unicode_manager)
local folder_warning = false
for _, warning in ipairs(unicode_warnings) do
    if warning == "folder_not_writable.group.测试" then folder_warning = true end
end
assert(not folder_warning, table.concat(unicode_warnings, ","))

print("VoiceControllerConfigManager tests passed")
