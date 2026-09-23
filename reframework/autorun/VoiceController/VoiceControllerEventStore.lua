-- VoiceController 固定容量事件存储。
-- 仅由 REFramework Lua 帧线程写入和读取；存储拥有事件表引用，聚合命中会移动到队尾，Hook 不执行数组整理。

local EventStore = {}
local ActionContext = require("VoiceController/VoiceControllerActionContext")

-- 创建固定容量环形队列；capacity 必须是正整数。
function EventStore.new(capacity)
    assert(type(capacity) == "number" and capacity >= 1, "capacity must be positive")
    return {
        capacity = math.floor(capacity),
        items = {},
        latest_by_key = {},
        size = 0,
        total_pushed = 0
    }
end

-- 追加事件并在容量满后覆盖最旧项；调用方不得在追加后继续修改事件表。
function EventStore.push(store, event)
    assert(store and event, "store and event are required")
    store.items[#store.items + 1] = event
    if #store.items > store.capacity then
        -- 已识别分类作为关注事件保留，普通未分类音频优先淘汰；全部为关注事件时才淘汰最旧项。
        local remove_index = 1
        for index, item in ipairs(store.items) do
            if item.pinned ~= true then
                remove_index = index
                break
            end
        end
        local removed = table.remove(store.items, remove_index)
        if removed and store.latest_by_key[removed.stableKey] == removed then
            store.latest_by_key[removed.stableKey] = nil
        end
    end
    if event.stableKey then store.latest_by_key[event.stableKey] = event end
    store.size = #store.items
    store.total_pushed = store.total_pushed + 1
end

-- 在滚动时间窗内合并同一稳定键；返回 true 表示新增行，false 表示只更新触发次数。
function EventStore.push_coalesced(store, event, window_ms)
    assert(store and event, "store and event are required")
    local key = event.stableKey
    local previous = key and store.latest_by_key[key] or nil
    local observed_at = tonumber(event.observedAtMs) or 0
    local previous_at = previous and tonumber(previous.lastObservedAtMs or previous.observedAtMs) or nil
    if previous and previous_at and observed_at - previous_at <= (tonumber(window_ms) or 0) then
        previous.sequence = event.sequence
        previous.lastObservedAtMs = observed_at
        previous.lastCapturedAt = event.capturedAt
        previous.triggerCount = (tonumber(previous.triggerCount) or 1) + 1
        previous.origin = event.origin
        previous.category = event.category
        previous.sourcePath = event.sourcePath or previous.sourcePath
        previous.sourceObject = event.sourceObject or previous.sourceObject
        previous.targetObject = event.targetObject or previous.targetObject
        local merged_actions = ActionContext.merge(previous.observedActions, event.observedActions)
        previous.observedActions = #merged_actions > 0 and merged_actions or nil
        previous.replacement = event.replacement
        previous.replayable = event.replayable == true
        for index, item in ipairs(store.items) do
            if item == previous then
                table.remove(store.items, index)
                store.items[#store.items + 1] = previous
                break
            end
        end
        store.total_pushed = store.total_pushed + 1
        return false
    end
    event.triggerCount = tonumber(event.triggerCount) or 1
    event.firstCapturedAt = event.firstCapturedAt or event.capturedAt
    event.lastCapturedAt = event.lastCapturedAt or event.capturedAt
    event.lastObservedAtMs = observed_at
    EventStore.push(store, event)
    return true
end

-- 按稳定键返回本会话最近一次聚合记录；调用方不得修改返回表。
function EventStore.find_latest(store, stable_key)
    return store and store.latest_by_key and store.latest_by_key[stable_key] or nil
end

-- 返回按捕获先后排序的浅拷贝，供帧线程生成 JSON 快照。
function EventStore.to_array(store)
    local result = {}
    if not store or store.size == 0 then return result end

    for _, event in ipairs(store.items) do result[#result + 1] = event end
    return result
end

return EventStore
