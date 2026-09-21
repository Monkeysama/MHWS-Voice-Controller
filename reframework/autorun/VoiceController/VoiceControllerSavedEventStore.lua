-- VoiceController 永久收藏事件存储。
-- 仅由 REFF/帧线程调用；模块拥有 JSON 数据副本，写入采用暂存校验、备份和失败回写，Hook 不访问文件系统。

local Store = {}

local function copy_json(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy_json(item) end
    return result
end

local function normalize_uint(value)
    local text = tostring(value or "")
    return string.match(text, "^%d+$") and text or nil
end

local function normalize_note(value)
    if value == nil then return nil end
    local text = string.gsub(string.gsub(tostring(value), "^%s+", ""), "%s+$", "")
    return text ~= "" and text or nil
end

local function normalize_event(event)
    if type(event) ~= "table" then return nil, "invalid_event" end
    local event_id = normalize_uint(event.eventId)
    local trigger_id = normalize_uint(event.triggerId)
    if not event_id or not trigger_id then return nil, "invalid_event" end
    local category = tostring(event.category or "unknown")
    -- 兼容早期版本使用的 voice 分类；当前 UI 和持久解析统一使用 player。
    if category == "voice" then category = "player" end
    return {
        stableKey = event_id .. ":" .. trigger_id,
        eventId = event_id,
        triggerId = trigger_id,
        category = category,
        sourcePath = event.sourcePath,
        sourceObject = event.sourceObject,
        targetObject = event.targetObject,
        container = event.container,
        offsetJointHash = tonumber(event.offsetJointHash) or 0,
        origin = event.origin,
        note = normalize_note(event.note),
        savedAt = event.savedAt,
        lastCapturedAt = event.lastCapturedAt or event.capturedAt,
        durationMs = tonumber(event.durationMs)
    }
end

local function default_read(path)
    if fs and type(fs.read) == "function" then return fs.read(path) end
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function default_write(path, content)
    if fs and type(fs.write) == "function" then
        local ok, result = pcall(fs.write, path, content)
        return ok and result ~= false
    end
    local file = io.open(path, "wb")
    if not file then return false end
    local ok = file:write(content)
    file:close()
    return ok ~= nil
end

local function normalize_document(document)
    document = type(document) == "table" and document or {}
    local events = {}
    local seen = {}
    for _, raw in ipairs(type(document.events) == "table" and document.events or {}) do
        local event = normalize_event(raw)
        if event and not seen[event.stableKey] then
            seen[event.stableKey] = true
            events[#events + 1] = event
        end
    end
    return {schemaVersion = 1, events = events}
end

local function persist(store, document)
    local encode_ok, payload = pcall(store.encode, document)
    if not encode_ok or type(payload) ~= "string" or payload == "" then return false, "encode_failed" end
    local temporary = store.path .. ".tmp"
    local backup = store.path .. ".bak"
    if not store.write(temporary, payload) then return false, "temporary_write_failed" end
    local temporary_content = store.read(temporary)
    local verify_ok, decoded = pcall(store.decode, temporary_content or "")
    if not verify_ok or type(decoded) ~= "table" then return false, "temporary_verify_failed" end

    local original = store.read(store.path)
    if original ~= nil and not store.write(backup, original) then return false, "backup_write_failed" end
    if not store.write(store.path, payload) then
        if original ~= nil then store.write(store.path, original) end
        return false, "target_write_failed"
    end
    local target = store.read(store.path)
    local target_ok, target_document = pcall(store.decode, target or "")
    if target ~= payload or not target_ok or type(target_document) ~= "table" then
        if original ~= nil then store.write(store.path, original) end
        return false, "target_verify_failed"
    end
    return true
end

-- 加载收藏文件；文件不存在时创建空内存集合，直到首次收藏才写盘。
function Store.load(path, file_api)
    file_api = file_api or {}
    local read = file_api.read or default_read
    local decode = file_api.decode or json.load_string
    local content = read(path)
    local document = {schemaVersion = 1, events = {}}
    -- REFramework fs.read 在文件不存在时可能返回 nil、false 或空字符串；这些都表示尚未创建收藏文件。
    if content ~= nil and content ~= false and tostring(content) ~= "" then
        local ok, decoded = pcall(decode, content)
        if not ok or type(decoded) ~= "table" then return nil, "saved_events_invalid" end
        document = normalize_document(decoded)
    end
    return {
        path = path,
        document = document,
        read = read,
        write = file_api.write or default_write,
        encode = file_api.encode or function(value) return json.dump_string(value, 2) end,
        decode = decode
    }
end

function Store.snapshot(store)
    return copy_json(store.document.events)
end

function Store.contains(store, stable_key)
    for _, event in ipairs(store.document.events) do
        if event.stableKey == stable_key then return true end
    end
    return false
end

-- 永久收藏近期事件；同一稳定键幂等，只有持久化成功才提交内存状态。
function Store.add(store, event, saved_at)
    local normalized, err = normalize_event(event)
    if not normalized then return false, err end
    if Store.contains(store, normalized.stableKey) then return false, "already_saved" end
    normalized.savedAt = saved_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
    local next_document = normalize_document(store.document)
    next_document.events[#next_document.events + 1] = normalized
    local saved, save_error = persist(store, next_document)
    if not saved then return false, save_error end
    store.document = next_document
    return true, normalized.stableKey
end

-- 更新收藏备注；空字符串表示清除，备注只属于保存列表，不写入或修改分组规则。
function Store.update_note(store, stable_key, note)
    if type(note) ~= "string" then return false, "invalid_note" end
    local normalized = normalize_note(note)
    -- UI 限制为 64 个字符；后端按 UTF-8 字节保留余量并拒绝异常大的直接调用。
    if normalized and #normalized > 256 then return false, "note_too_long" end
    local next_document = normalize_document(store.document)
    local updated = false
    for _, event in ipairs(next_document.events) do
        if event.stableKey == stable_key then
            event.note = normalized
            updated = true
            break
        end
    end
    if not updated then return false, "saved_event_not_found" end
    local saved, err = persist(store, next_document)
    if not saved then return false, err end
    store.document = next_document
    return true
end

-- 删除收藏记录；收藏与分组规则彼此独立，删除不会级联修改分组配置。
function Store.remove(store, stable_key)
    local next_document = normalize_document(store.document)
    local removed = false
    for index = #next_document.events, 1, -1 do
        if next_document.events[index].stableKey == stable_key then
            table.remove(next_document.events, index)
            removed = true
        end
    end
    if not removed then return false, "saved_event_not_found" end
    local saved, err = persist(store, next_document)
    if not saved then return false, err end
    store.document = next_document
    return true
end

return Store
