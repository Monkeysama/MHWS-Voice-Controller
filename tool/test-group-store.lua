-- GroupStore 自检：文件夹即分组、清单解析与相对路径、无清单文件夹、默认关闭导入、占用判定、清单回写。
package.path = "reframework/autorun/?.lua;" .. package.path
local GroupStore = require("VoiceController/VoiceControllerGroupStore")

-- 文件夹名校验
assert(GroupStore.normalize_folder("player-voice") == "player-voice")
assert(GroupStore.normalize_folder("测试分组") == "测试分组")
assert(GroupStore.normalize_folder("../evil") == nil)
assert(GroupStore.normalize_folder("a/b") == nil)
assert(GroupStore.normalize_folder("con") == "con")   -- 目录设备名由创建侧拒绝，这里只保证是单层段
assert(GroupStore.normalize_folder("") == nil)

-- 编码约束：REFramework 的 Lua 文件 API 按本机代码页解释路径，只有纯 ASCII 目录名可靠。
-- 真实故障：保存时把 Groups\测试 写成 Groups\娴嬭瘯（乱码目录），而读到的是同一批错误名字。
assert(GroupStore.is_valid_utf8("测试分组"))
assert(not GroupStore.is_valid_utf8("\xc4\xe3"))                 -- CP936 字节不是合法 UTF-8
assert(GroupStore.normalize_folder("\xc4\xe3") == nil)           -- 乱码名字直接拒绝，不能进入 JSON
assert(GroupStore.is_writable_folder("player-voice"))
assert(GroupStore.is_writable_folder("My Voices"))
assert(GroupStore.is_writable_folder("测试"))
assert(not GroupStore.is_writable_folder("a/b"))
local unwritable = GroupStore.unwritable_folders({
    {id = "a", audioDirectory = "VoiceController\\Groups\\测试\\Audio"},
    {id = "b", audioDirectory = "VoiceController\\Groups\\pack\\Audio"},
    {id = "c", audioDirectory = "VoiceController\\PlayerVoice\\Audio"},
})
assert(#unwritable == 0)

-- 由 audioDirectory 反推文件夹
assert(GroupStore.folder_of_group({audioDirectory = "VoiceController\\Groups\\测试\\Audio"}) == "测试")
assert(GroupStore.folder_of_group({audioDirectory = "VoiceController\\PlayerVoice\\Audio"}) == nil)
assert(GroupStore.folder_of_group({}) == nil)

-- 音频路径重写与越界拒绝
local full, rel = GroupStore.resolve_audio_path("测试", "Audio/hit.wav")
assert(full == "VoiceController\\Groups\\测试\\Audio\\hit.wav", full)
assert(rel == "hit.wav")
assert(GroupStore.resolve_audio_path("测试", "hit.ogg") == "VoiceController\\Groups\\测试\\Audio\\hit.ogg")
assert(GroupStore.resolve_audio_path("测试", "Audio/../x.wav") == nil)
assert(GroupStore.resolve_audio_path("测试", "Audio/sub/x.wav") == nil)
assert(GroupStore.resolve_audio_path("测试", "C:\\x.wav") == nil)
assert(GroupStore.resolve_audio_path("测试", "Audio/x.txt") == nil)

local catalog_index = {["voicecontroller\\groups\\测试\\audio\\hit.wav"] = true}

local function manifest(overrides)
    local base = {
        schemaVersion = 1,
        name = "测试语音",
        version = "1.0.0",
        rules = {{
            id = "r1", eventId = "3499935827", triggerId = "114982064", mode = "observe",
            candidates = {{file = "Audio/hit.wav", weight = 1}}
        }}
    }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

-- 清单解析
local body, errors = GroupStore.parse_manifest("测试", manifest(), catalog_index)
assert(body, errors and table.concat(errors, ","))
assert(body.folder == "测试" and body.name == "测试语音")
assert(body.audio_directory == "VoiceController\\Groups\\测试\\Audio")
assert(body.rules[1].candidates[1].file == "VoiceController\\Groups\\测试\\Audio\\hit.wav")
assert(#body.warnings == 0 and body.has_manifest == nil)
local _, bad_schema = GroupStore.parse_manifest("测试", manifest({schemaVersion = 9}), catalog_index)
assert(bad_schema[1] == "unsupported_group_schema")
local _, bad_rule = GroupStore.parse_manifest("测试", manifest({rules = {
    {id = "r", eventId = "1", triggerId = "2", mode = "replace",
     candidates = {{file = "Audio/hit.wav"}}},
}}), catalog_index)
assert(table.concat(bad_rule, ","):find("replace_strategy", 1, true) ~= nil, table.concat(bad_rule, ","))
-- 音频不在快照里只告警
local warned = GroupStore.parse_manifest("测试", manifest({rules = {
    {id = "r", eventId = "1", triggerId = "2", candidates = {{file = "Audio/pending.wav"}}},
}}), catalog_index)
assert(warned and warned.warnings[1] == "audio_missing.pending.wav")

-- fs.glob 是正则（std::regex_match 整串匹配）：模式必须写成 \\ 与 .*，原来的 "...\*" 等于永远匹配不到
assert(GroupStore.SCAN_PATTERN == "VoiceController[\\\\/]Groups[\\\\/].*", GroupStore.SCAN_PATTERN)

-- 文件夹发现：glob（本机代码页，只接受 ASCII 名）与原生 UTF-8 快照（可用中文名）并集
local folders, folder_rejects = GroupStore.collect_folders(function() return {
    "VoiceController\\Groups\\player-voice\\Audio\\a.wav",
    "VoiceController\\Groups\\娴嬭瘯\\Audio\\b.wav",   -- glob 里的中文名不可信（乱码名会被当成 UTF-8 读回来）
    "VoiceController\\Groups\\\xc4\xe3\\Audio\\c.wav", -- 真实 CP936 字节，连 UTF-8 都不是
    "VoiceController\\Packs\\demo-pack",
} end, {{relativePath = "Groups\\测试\\Audio\\a.wav"}})
assert(#folders == 3 and folders[1] == "player-voice" and folders[2] == "娴嬭瘯" and folders[3] == "测试", table.concat(folders, ","))
assert(#folder_rejects == 0, #folder_rejects)

-- 扫描：有清单 / 无清单 / 清单损坏；非 ASCII 目录不访问文件系统
local read_paths = {}
local scanned = GroupStore.scan({
    glob = function() return {
        "VoiceController\\Groups\\voice-pack\\Audio\\a.wav",
        "VoiceController\\Groups\\empty-folder\\Audio\\b.wav",
        "VoiceController\\Groups\\broken\\group.json",
    } end,
    catalog_files = {{relativePath = "Groups\\测试\\Audio\\hit.wav"}},
    read = function(path)
        read_paths[#read_paths + 1] = path
        if path:find("voice%-pack") then
            return '{"schemaVersion":1,"name":"Voice Pack","rules":[{"id":"r1","eventId":"1","triggerId":"2","candidates":[{"file":"Audio/hit.wav"}]}]}'
        elseif path:find("broken", 1, true) then
            return "not json"
        end
        return nil
    end,
    decode = function(text)
        if text == "not json" then error("bad json") end
        return {schemaVersion = 1, name = "Voice Pack",
            rules = {{id = "r1", eventId = "1", triggerId = "2",
                candidates = {{file = "Audio/hit.wav"}}}}}
    end,
})
local by_folder = {}
for _, entry in ipairs(scanned.groups) do by_folder[entry.folder] = entry end
assert(#scanned.groups == 3, #scanned.groups)
assert(by_folder["empty-folder"] ~= nil and by_folder["empty-folder"].has_manifest == false)
assert(#by_folder["empty-folder"].rules == 0)
assert(by_folder["empty-folder"].writable == true)
assert(by_folder["voice-pack"] ~= nil and by_folder["voice-pack"].has_manifest == true)
-- 非 ASCII 目录：来自原生 UTF-8 快照，可被发现并由 UTF-8 桥读写清单
assert(by_folder["测试"] ~= nil and by_folder["测试"].writable == true)
assert(by_folder["测试"].has_manifest == false)
assert(#scanned.rejects == 1 and scanned.rejects[1].id == "broken")

-- 合成：已有分组保持本地状态，新文件夹导入为默认关闭
local local_config = {
    schemaVersion = 2, enabled = true, mode = "observe",
    groups = {{id = "测试", name = "测试语音", enabled = true,
        audioDirectory = "VoiceController\\Groups\\测试\\Audio",
        rules = {{id = "r1", eventId = "1", triggerId = "2", mode = "observe",
            candidates = {{file = "VoiceController\\Groups\\测试\\Audio\\hit.wav"}}}}}},
}
local effective, info = GroupStore.compose(local_config, {
    groups = {
        {folder = "测试", name = "测试语音", audio_directory = "VoiceController\\Groups\\测试\\Audio",
         rules = {}, warnings = {}, has_manifest = true},
        {folder = "新分组", name = "新分组", audio_directory = "VoiceController\\Groups\\新分组\\Audio",
         rules = {{id = "n1", eventId = "5", triggerId = "6", mode = "observe",
             candidates = {{file = "VoiceController\\Groups\\新分组\\Audio\\n.wav"}}}},
         warnings = {}, has_manifest = true},
    }
})
assert(#effective.groups == 2, #effective.groups)
assert(effective.groups[1].id == "测试" and effective.groups[1].enabled == true)
assert(effective.groups[2].id == "新分组" and effective.groups[2].enabled == false, "新分组必须默认关闭")
assert(effective.groups[2].source.folder == "新分组")
assert(effective.groups[2].source.hasManifest == true)
-- 非 ASCII 目录名可以导入、播放并通过 UTF-8 桥回写清单
assert(effective.groups[2].source.writable == true)
assert(effective.groups[1].source == nil or effective.groups[1].source.writable == nil)
assert(#info.unwritable == 0)
assert(#info.imported == 1 and info.imported[1] == "新分组")
assert(info.origin["测试"].origin == "folder")
-- 合成不得改动本地配置
assert(#local_config.groups == 1 and local_config.groups[1].enabled == true)
-- 本地 JSON 中的目录已被删除时，合成运行时也必须剔除幽灵分组。
local without_folder = GroupStore.compose(local_config, {groups = {}})
assert(#without_folder.groups == 0)
local case_only = GroupStore.compose({schemaVersion = 2, groups = {{
    id = "case", audioDirectory = "VoiceController\\Groups\\Player-Voice\\Audio", rules = {}
}}}, {groups = {{
    folder = "player-voice", name = "Player Voice",
    audio_directory = "VoiceController\\Groups\\player-voice\\Audio", rules = {}
}}})
assert(#case_only.groups == 1, "目录匹配必须遵循 Windows 的不区分大小写语义")
-- 无清单的空文件夹也会导入为空规则分组
local empty_effective, empty_info = GroupStore.compose({schemaVersion = 2, groups = {}}, {
    groups = {{folder = "空目录", name = "空目录",
        audio_directory = "VoiceController\\Groups\\空目录\\Audio",
        rules = {}, warnings = {}, has_manifest = false}}
})
assert(#empty_effective.groups == 1 and empty_effective.groups[1].enabled == false)
assert(empty_effective.groups[1].rules._empty == true, "空规则用 _empty 标记，避免 JSON 编码成 null")
assert(#empty_info.imported == 1)

-- 占用判定：先启用先赢
local conflicts = GroupStore.collect_conflicts({
    {id = "a", name = "A", enabled = true,
     rules = {{id = "r", eventId = "1", triggerId = "1", mode = "observe"}}},
    {id = "b", name = "B", enabled = true,
     rules = {{id = "r", eventId = "1", triggerId = "1", mode = "overlay"}}},
    {id = "c", name = "C", enabled = false,
     rules = {{id = "r", eventId = "1", triggerId = "1", mode = "observe"}}},
})
assert(#conflicts == 1 and conflicts[1].winner.group_id == "a")
assert(#conflicts[1].losers == 2)
assert(conflicts[1].losers[1].group_id == "b" and conflicts[1].losers[1].enabled == true)
assert(conflicts[1].losers[2].group_id == "c" and conflicts[1].losers[2].enabled == false)

-- 清单回写：候选变回相对路径，整个文件夹可以搬走
local document = GroupStore.to_document({
    id = "测试", name = "测试语音",
    audioDirectory = "VoiceController\\Groups\\测试\\Audio",
    rules = {{id = "r1", eventId = "1", triggerId = "2", mode = "observe", cooldownMs = 200,
        candidates = {{file = "VoiceController\\Groups\\测试\\Audio\\hit.wav", weight = 1, volume = 0.5}}}},
}, "skip_original")
assert(document.schemaVersion == 1 and document.name == "测试语音")
assert(document.rules[1].candidates[1].file == "Audio\\hit.wav",
    document.rules[1].candidates[1].file)
assert(document.rules[1].cooldownMs == 200)
local replace_document = GroupStore.to_document({
    id = "测试", name = "测试语音",
    audioDirectory = "VoiceController\\Groups\\测试\\Audio",
    rules = {{id = "r1", eventId = "1", triggerId = "2", mode = "replace",
        candidates = {{file = "VoiceController\\Groups\\测试\\Audio\\hit.wav"}}}}
}, "skip_original")
assert(replace_document.rules[1].replaceStrategy == "skip_original")
-- 回写 -> 再解析必须得到同一份运行时分组
local roundtrip = assert(GroupStore.parse_manifest("测试", document, nil))
assert(roundtrip.name == document.name)
assert(roundtrip.rules[1].candidates[1].file
    == "VoiceController\\Groups\\测试\\Audio\\hit.wav")

print("VoiceControllerGroupStore tests passed")
