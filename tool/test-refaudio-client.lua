-- REFAudio 命令客户端自检；通过内存文件适配器验证协议，不访问实际游戏目录。

package.path = "reframework/autorun/?.lua;" .. package.path

local Client = require("VoiceController/VoiceControllerREFAudioClient")
local written = nil
local channel_snapshot = ""
local client = Client.new({
    read_all = function(path)
        if path == "REFAudio\\audio_backend.txt" then
            return "REFAudio\t1\tmultichannel=1\tmax_channels=32"
        end
        if path == "REFAudio\\audio_channels.txt" then return channel_snapshot end
        return nil
    end,
    file_exists = function(path)
        return path == "VoiceController\\Audio\\test.wav"
    end,
    write_all = function(path, content)
        assert(path == "REFAudio\\audio_command.txt")
        written = content
        return true
    end
})

local ready, preflight_error = Client.preflight(client, "VoiceController\\Audio\\test.wav", 0)
assert(ready and preflight_error == nil)

assert(Client.enqueue_load(client, {
    source = "test",
    stable_key = "3499935827:114982064",
    file = "VoiceController\\Audio\\test.wav",
    volume = 0.8,
    speed = 1.1,
    max_duration_ms = 1500
}))

local result = Client.tick(client, 0)
assert(result and result.kind == "submitted")
assert(result.source == "test")
local fields = {}
for field in string.gmatch(written .. "\t", "([^\t]*)\t") do fields[#fields + 1] = field end
assert(#fields == 8)
assert(fields[3] == "load")
assert(fields[5] == "VoiceController\\Audio\\test.wav")
assert(fields[8] == "1.5")

local function positioned(x, y, z)
    return {call = function(_, method)
        if method == "get_Transform" then
            return {call = function(_, transform_method)
                if transform_method == "get_Position" then return {x = x, y = y, z = z} end
            end}
        end
    end}
end
assert(Client.enqueue_load(client, {
    stable_key = "distance",
    file = "VoiceController\\Audio\\test.wav",
    volume = 0.8,
    speed = 1,
    max_duration_ms = 0,
    source_object = positioned(16, 0, 0),
    listener_object = positioned(0, 0, 0),
    distance_enabled = true
}))
result = Client.tick(client, 0.2)
assert(result and result.kind == "submitted")
fields = {}
for field in string.gmatch(written .. "\t", "([^\t]*)\t") do fields[#fields + 1] = field end
assert(tonumber(fields[6]) < 0.1 and tonumber(fields[6]) > 0)

local moving = {x = 16, y = 0, z = 0}
local moving_source = {call = function(_, method)
    if method == "get_Transform" then
        return {call = function(_, transform_method)
            if transform_method == "get_Position" then return moving end
        end}
    end
end}
local listener = positioned(0, 0, 0)
assert(Client.enqueue_load(client, {
    stable_key = "moving",
    file = "VoiceController\\Audio\\test.wav",
    volume = 1,
    speed = 1,
    source_object = moving_source,
    listener_object = listener,
    distance_enabled = true
}))
result = Client.tick(client, 0.3)
assert(result and result.kind == "submitted")
channel_snapshot = "1447235586\tplaying\t0\t1\t1\t0"
moving.x = 32
Client.update_spatial(client, 0.41)
result = Client.tick(client, 0.51)
assert(result and result.kind == "submitted" and result.source == "spatial")
fields = {}
for field in string.gmatch(written .. "\t", "([^\t]*)\t") do fields[#fields + 1] = field end
assert(fields[3] == "volume" and fields[4] == "1447235586" and tonumber(fields[5]) < 0.1)

assert(Client.enqueue_load(client, {
    stable_key = "missing",
    file = "VoiceController\\Audio\\missing.ogg",
    volume = 1,
    speed = 1,
    max_duration_ms = 0
}))
result = Client.tick(client, 0.6)
assert(result and result.kind == "error" and result.reason == "audio_file_missing")
assert(result.source == "replacement")
local status = Client.get_status(client)
assert(status.pending == 0 and status.submitted == 4 and status.failed == 1)
ready, preflight_error = Client.preflight(client, "VoiceController\\Audio\\missing.ogg", 1.1)
assert(not ready and preflight_error == "audio_file_missing")

assert(Client.enqueue_ensure_group_directory(client,
    "VoiceController\\Groups\\combat\\Audio"))
result = Client.tick(client, 0.7)
assert(result and result.kind == "submitted" and result.source == "group-directory")
fields = {}
for field in string.gmatch(written .. "\t", "([^\t]*)\t") do fields[#fields + 1] = field end
assert(fields[3] == "ensure_dir" and fields[5] == "VoiceController\\Groups\\combat\\Audio")

assert(Client.enqueue_ensure_group_directory(client,
    "VoiceController\\Groups\\测试分组\\Audio"))
result = Client.tick(client, 0.8)
assert(result and result.kind == "submitted" and result.source == "group-directory")
fields = {}
for field in string.gmatch(written .. "\t", "([^\t]*)\t") do fields[#fields + 1] = field end
assert(fields[3] == "ensure_dir" and fields[5] == "VoiceController\\Groups\\测试分组\\Audio")

print("VoiceControllerREFAudioClient tests passed")
