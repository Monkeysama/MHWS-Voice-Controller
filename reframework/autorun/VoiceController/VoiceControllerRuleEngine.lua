-- VoiceController 精确事件规则引擎。
-- 纯 Lua 模块，不访问游戏对象或文件；配置由帧线程编译，音频 Hook 只执行常数时间匹配。

local RuleEngine = {}

local function add_error(errors, code)
    errors[#errors + 1] = code
end

local function normalize_uint(value)
    local text
    if type(value) == "number" then
        if value < 0 or value ~= math.floor(value) then return nil end
        text = string.format("%.0f", value)
    else
        text = tostring(value or "")
    end
    if string.match(text, "^%d+$") == nil then return nil end
    return text
end

-- 规范化相对于 reframework/data 的音频路径，禁止绝对路径和父目录跳转。
local function normalize_audio_path(value)
    if type(value) ~= "string" or value == "" then return nil end
    if string.find(value, "[\t\r\n]") then return nil end

    local path = string.gsub(value, "/", "\\")
    if string.match(path, "^[\\]") or string.match(path, "^%a:") then return nil end
    for segment in string.gmatch(path, "[^\\]+") do
        if segment == ".." then return nil end
    end
    if string.sub(string.lower(path), 1, 16) ~= "voicecontroller\\" then return nil end
    local lowered = string.lower(path)
    if not string.match(lowered, "%.mp3$")
        and not string.match(lowered, "%.ogg$")
        and not string.match(lowered, "%.wav$")
    then
        return nil
    end
    return path
end

local function bounded_number(value, default, minimum, maximum)
    local number = tonumber(value)
    if number == nil then return default end
    if number < minimum or number > maximum then return nil end
    return number
end

-- 将磁盘配置编译成 Hook 可直接读取的规则；任何错误都令规则保持关闭。
function RuleEngine.compile(config)
    local errors = {}
    config = type(config) == "table" and config or {}

    local event_id = normalize_uint(config.eventId)
    local trigger_id = normalize_uint(config.triggerId)
    local mode = config.mode or "observe"
    local file = normalize_audio_path(config.file)
    local volume = bounded_number(config.volume, 1.0, 0.0, 1.0)
    local speed = bounded_number(config.speed, 1.0, 0.1, 8.0)
    local max_duration_ms = bounded_number(config.maxDurationMs, 0, 0, 3600000)
    local cooldown_ms = bounded_number(config.cooldownMs, 0, 0, 3600000)

    if config.schemaVersion ~= 1 then add_error(errors, "unsupported_schema") end
    if event_id == nil then add_error(errors, "invalid_event_id") end
    if trigger_id == nil then add_error(errors, "invalid_trigger_id") end
    if mode ~= "observe" and mode ~= "overlay" and mode ~= "replace" then
        add_error(errors, "unsupported_mode")
    end
    if (mode == "overlay" or mode == "replace") and file == nil then
        add_error(errors, "invalid_audio_path")
    end
    if mode == "replace"
        and config.replaceStrategy ~= "stop_playing_id"
        and config.replaceStrategy ~= "skip_original"
    then
        add_error(errors, "invalid_replace_strategy")
    end
    if volume == nil then add_error(errors, "invalid_volume") end
    if speed == nil then add_error(errors, "invalid_speed") end
    if max_duration_ms == nil then add_error(errors, "invalid_max_duration") end
    if cooldown_ms == nil then add_error(errors, "invalid_cooldown") end
    if config.fallbackToOriginal == false then add_error(errors, "fallback_required") end

    local valid = #errors == 0
    return {
        enabled = config.enabled == true and valid,
        valid = valid,
        errors = errors,
        event_id = event_id,
        trigger_id = trigger_id,
        stable_key = event_id and trigger_id and (event_id .. ":" .. trigger_id) or nil,
        mode = valid and mode or "observe",
        replace_strategy = config.replaceStrategy,
        file = file,
        volume = volume or 1.0,
        speed = speed or 1.0,
        max_duration_ms = max_duration_ms or 0,
        cooldown_ms = cooldown_ms or 0,
        last_trigger_ms = nil
    }
end

-- 精确匹配 EventId 与 TriggerId；observe 规则仅返回匹配结果，不请求外部播放。
function RuleEngine.match(rule, event_id, trigger_id)
    if not rule or not rule.enabled then return false end
    return rule.event_id == normalize_uint(event_id) and rule.trigger_id == normalize_uint(trigger_id)
end

-- 在 Hook 内执行轻量冷却门控；时间由调用方传入，便于测试且不访问系统资源。
function RuleEngine.accept(rule, now_ms)
    if not rule or rule.mode == "observe" then return false, "observe" end
    if rule.last_trigger_ms ~= nil and now_ms - rule.last_trigger_ms < rule.cooldown_ms then
        return false, "cooldown"
    end
    rule.last_trigger_ms = now_ms
    return true, rule.mode
end

return RuleEngine
