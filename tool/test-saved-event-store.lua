-- 永久收藏存储自检；文件 API 使用内存替身，验证幂等、删除和失败前不提交内存。

package.path = "reframework/autorun/?.lua;" .. package.path
local Store = require("VoiceController/VoiceControllerSavedEventStore")

local files = {}
local api = {
    read = function(path) return files[path] end,
    write = function(path, content) files[path] = content return true end,
    encode = function(document)
        local parts = {}
        for _, event in ipairs(document.events) do
            parts[#parts + 1] = event.eventId .. ":" .. event.triggerId
        end
        return "E|" .. table.concat(parts, ",")
    end,
    decode = function(content)
        local events = {}
        for event_id, trigger_id in string.gmatch(content, "(%d+):(%d+)") do
            events[#events + 1] = {eventId = event_id, triggerId = trigger_id}
        end
        return {schemaVersion = 1, events = events}
    end
}
local store = assert(Store.load("VoiceController\\saved_events.json", api))
assert(Store.add(store, {eventId = "1", triggerId = "2", sourcePath = "voice"}, "now"))
local first = Store.snapshot(store)[1]
assert(#Store.snapshot(store) == 1 and Store.contains(store, "1:2") and first.category == "unknown")
assert(Store.remove(store, "1:2"))
assert(Store.add(store, {eventId = "3", triggerId = "4", category = "voice"}, "now"))
assert(Store.snapshot(store)[1].category == "player")
local ok, err = Store.add(store, {eventId = "3", triggerId = "4"})
assert(not ok and err == "already_saved")
assert(Store.remove(store, "3:4") and #Store.snapshot(store) == 0)

print("VoiceControllerSavedEventStore tests passed")
