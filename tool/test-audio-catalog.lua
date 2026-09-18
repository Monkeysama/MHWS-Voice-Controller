-- VoiceController 音频目录扫描器纯 Lua 自检；文件枚举完全由内存替身提供。

package.path = "reframework/autorun/?.lua;" .. package.path

local Catalog = require("VoiceController/VoiceControllerAudioCatalog")

local snapshot = Catalog.scan(function(pattern)
    assert(pattern == [[VoiceController\\.*]])
    return {
        "VoiceController\\Zeta\\Audio\\z.wav",
        "VoiceController/Alpha/Audio/a.OGG",
        "data\\VoiceController\\Beta\\b.mp3",
        "reframework\\data\\VoiceController\\alpha\\audio\\A.ogg",
        "VoiceController\\Alpha\\notes.txt",
        "Other\\outside.wav",
        "VoiceController\\Alpha\\..\\escape.wav",
        false
    }
end, "2026-09-16T00:00:00Z")

assert(snapshot.schemaVersion == 1 and snapshot.count == 3)
assert(snapshot.capturedAt == "2026-09-16T00:00:00Z")
assert(snapshot.files[1].file == "VoiceController\\Alpha\\Audio\\a.OGG")
assert(snapshot.files[1].extension == "ogg")
assert(snapshot.files[1].groupDirectory == "Alpha")
assert(snapshot.files[2].file == "VoiceController\\Beta\\b.mp3")
assert(snapshot.files[3].file == "VoiceController\\Zeta\\Audio\\z.wav")
assert(snapshot.stats.returned == 8)
assert(snapshot.stats.accepted == 3)
assert(snapshot.stats.duplicates == 1)
assert(snapshot.stats.unsupported == 1)
assert(snapshot.stats.outsideRoot == 1)
assert(snapshot.stats.invalid == 2)
assert(#snapshot.errors == 0)

local partial = Catalog.scan(function(pattern)
    if pattern == "broken" then error("enumeration denied") end
    if pattern == "invalid" then return "not-a-table" end
    return {"VoiceController\\Audio\\ok.wav"}
end, nil, {"ok", "broken", "invalid"})
assert(partial.count == 1 and #partial.errors == 2)
assert(partial.errors[1].code == "glob_failed")
assert(partial.errors[2].code == "glob_invalid_result")

local unavailable = Catalog.scan(nil)
assert(unavailable.count == 0 and unavailable.errors[1].code == "glob_unavailable")

local unicode_manifest = table.concat({
    "REFAudioCatalog\t1",
    "VoiceController\\Groups\\测试分组\\Audio\\测试.wav",
    "VoiceController\\Groups\\目录验证\\Audio\\voice.ogg",
    "END\t2",
    ""
}, "\n")
local native_paths, manifest_error = Catalog.parse_native_manifest(unicode_manifest)
assert(native_paths and manifest_error == nil and #native_paths == 2)
local unicode_snapshot = Catalog.scan(function() return native_paths end)
assert(unicode_snapshot.count == 2)
assert(unicode_snapshot.files[1].file
    == "VoiceController\\Groups\\测试分组\\Audio\\测试.wav")
assert(Catalog.parse_native_manifest("REFAudioCatalog\t1\npath.wav\n") == nil)
assert(Catalog.parse_native_manifest("REFAudioCatalog\t1\nEND\t1\n") == nil)

local invalid_encoding = "VoiceController\\" .. string.char(0xB2, 0xE2) .. "\\bad.wav"
local encoding_snapshot = Catalog.scan(function() return {invalid_encoding} end)
assert(encoding_snapshot.count == 0 and encoding_snapshot.stats.invalid == 1)

print("VoiceControllerAudioCatalog tests passed")
