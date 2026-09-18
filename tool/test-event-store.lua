-- 近期事件聚合自检；验证同一稳定键在窗口内只更新次数，超出窗口后创建新行。

package.path = "reframework/autorun/?.lua;" .. package.path
local Store = require("VoiceController/VoiceControllerEventStore")

local store = Store.new(3)
assert(Store.push_coalesced(store, {stableKey = "1:2", sequence = 1, observedAtMs = 1000}, 2000))
assert(not Store.push_coalesced(store, {stableKey = "1:2", sequence = 2, observedAtMs = 2500}, 2000))
local items = Store.to_array(store)
assert(#items == 1 and items[1].triggerCount == 2 and items[1].sequence == 2)
assert(Store.push_coalesced(store, {stableKey = "1:2", sequence = 3, observedAtMs = 5001}, 2000))
items = Store.to_array(store)
assert(#items == 2 and items[2].triggerCount == 1)
assert(Store.find_latest(store, "1:2") == items[2])

local pinned = Store.new(2)
Store.push(pinned, {stableKey = "voice", pinned = true})
Store.push(pinned, {stableKey = "ambient-1"})
Store.push(pinned, {stableKey = "ambient-2"})
local pinned_items = Store.to_array(pinned)
assert(#pinned_items == 2 and Store.find_latest(pinned, "voice") ~= nil and Store.find_latest(pinned, "ambient-1") == nil)

print("VoiceControllerEventStore tests passed")
