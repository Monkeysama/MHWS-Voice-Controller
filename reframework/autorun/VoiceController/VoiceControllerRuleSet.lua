-- VoiceController 分组规则集。
-- 由帧线程编译配置，Hook 线程只读取编译结果；规则对象拥有冷却和并发计数，音频资源仍由 REFAudio 工作线程拥有。

local RuleSet = {}

local MAX_CONCURRENT = 32
local MAX_VOLUME = 2.0
-- REFAudio 外部通道目前没有把自然结束回调传回 Lua；未指定最大时长时用短租约释放并发令牌，避免一次播放永久锁死规则。
local DEFAULT_TOKEN_LEASE_MS = 2000

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

-- 规范化外部音频路径；规则集不允许绝对路径或父目录跳转。
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

local function compile_candidate(candidate, defaults, errors, label)
    candidate = type(candidate) == "table" and candidate or {}
    local file = normalize_audio_path(candidate.file)
    local weight = bounded_number(candidate.weight, 1.0, 0.000001, 1000000)
    local volume = bounded_number(candidate.volume, defaults.volume, 0.0, MAX_VOLUME)
    local speed = bounded_number(candidate.speed, defaults.speed, 0.1, 8.0)
    local max_duration_ms = bounded_number(
        candidate.maxDurationMs, defaults.max_duration_ms, 0, 3600000)

    if file == nil then add_error(errors, label .. ".invalid_audio_path") end
    if weight == nil then add_error(errors, label .. ".invalid_weight") end
    if volume == nil then add_error(errors, label .. ".invalid_volume") end
    if speed == nil then add_error(errors, label .. ".invalid_speed") end
    if max_duration_ms == nil then add_error(errors, label .. ".invalid_max_duration") end

    return {
        file = file,
        weight = weight or 0,
        volume = volume or defaults.volume,
        speed = speed or defaults.speed,
        max_duration_ms = max_duration_ms or defaults.max_duration_ms
    }
end

local function compile_rule(raw_rule, group, defaults, errors, index)
    raw_rule = type(raw_rule) == "table" and raw_rule or {}
    local label = string.format("groups.%s.rules.%d", group.id, index)
    local event_id = normalize_uint(raw_rule.eventId)
    local trigger_id = normalize_uint(raw_rule.triggerId)
    local cooldown_ms = bounded_number(raw_rule.cooldownMs, defaults.cooldown_ms, 0, 3600000)
    local max_concurrent = bounded_number(
        raw_rule.maxConcurrent, defaults.max_concurrent, 1, MAX_CONCURRENT)
    local mode = raw_rule.mode or defaults.mode
    local strategy = raw_rule.replaceStrategy or defaults.replace_strategy
    local raw_candidates = raw_rule.candidates
    if raw_candidates == nil and raw_rule.file ~= nil then
        raw_candidates = {{
            file = raw_rule.file,
            weight = 1,
            volume = raw_rule.volume,
            speed = raw_rule.speed,
            maxDurationMs = raw_rule.maxDurationMs
        }}
    end

    if event_id == nil then add_error(errors, label .. ".invalid_event_id") end
    if trigger_id == nil then add_error(errors, label .. ".invalid_trigger_id") end
    if mode ~= "observe" and mode ~= "overlay" and mode ~= "replace" then
        add_error(errors, label .. ".unsupported_mode")
    end
    if mode == "replace"
        and strategy ~= "stop_playing_id"
        and strategy ~= "skip_original"
    then
        add_error(errors, label .. ".invalid_replace_strategy")
    end
    if cooldown_ms == nil then add_error(errors, label .. ".invalid_cooldown") end
    if max_concurrent == nil then add_error(errors, label .. ".invalid_concurrency") end
    if type(raw_candidates) ~= "table" or #raw_candidates == 0 then
        add_error(errors, label .. ".missing_candidates")
    end

    local candidates = {}
    local total_weight = 0
    for candidate_index, candidate in ipairs(raw_candidates or {}) do
        local compiled = compile_candidate(
            candidate, defaults, errors,
            string.format("%s.candidates.%d", label, candidate_index))
        candidates[#candidates + 1] = compiled
        total_weight = total_weight + compiled.weight
    end
    if total_weight <= 0 then add_error(errors, label .. ".zero_total_weight") end

    return {
        id = tostring(raw_rule.id or (group.id .. ":" .. tostring(index))),
        group_id = group.id,
        enabled = raw_rule.enabled ~= false and group.enabled,
        event_id = event_id,
        trigger_id = trigger_id,
        stable_key = event_id and trigger_id and (event_id .. ":" .. trigger_id) or nil,
        mode = mode,
        replace_strategy = strategy,
        cooldown_ms = cooldown_ms or defaults.cooldown_ms,
        max_concurrent = max_concurrent or 1,
        candidates = candidates,
        total_weight = total_weight,
        last_trigger_ms = nil,
        active_count = 0,
        active_tokens = {},
        next_token_id = 0
    }
end

-- 编译 v2 分组配置；错误只返回诊断，不让不完整规则进入 Hook 热路径。
function RuleSet.compile(config)
    local errors = {}
    local warnings = {}
    config = type(config) == "table" and config or {}
    local mode = config.mode or "observe"
    local defaults = {
        mode = mode,
        replace_strategy = config.replaceStrategy,
        volume = bounded_number(config.volume, 1.0, 0.0, MAX_VOLUME) or 1.0,
        speed = bounded_number(config.speed, 1.0, 0.1, 8.0) or 1.0,
        max_duration_ms = bounded_number(config.maxDurationMs, 0, 0, 3600000) or 0,
        cooldown_ms = bounded_number(config.cooldownMs, 0, 0, 3600000) or 0,
        max_concurrent = bounded_number(config.maxConcurrent, 1, 1, MAX_CONCURRENT) or 1
    }
    if config.schemaVersion ~= 2 then add_error(errors, "unsupported_schema") end
    if mode ~= "observe" and mode ~= "overlay" and mode ~= "replace" then
        add_error(errors, "unsupported_mode")
    end
    if mode == "replace"
        and defaults.replace_strategy ~= "stop_playing_id"
        and defaults.replace_strategy ~= "skip_original"
    then
        add_error(errors, "invalid_replace_strategy")
    end
    if type(config.groups) ~= "table" then add_error(errors, "missing_groups") end

    local rules = {}
    local by_key = {}
    local key_groups = {}
    for group_index, raw_group in ipairs(config.groups or {}) do
        raw_group = type(raw_group) == "table" and raw_group or {}
        local group = {
            id = tostring(raw_group.id or ("group_" .. tostring(group_index))),
            name = tostring(raw_group.name or raw_group.id or ("group_" .. tostring(group_index))),
            enabled = raw_group.enabled ~= false
        }
        if type(raw_group.rules) ~= "table" then
            add_error(errors, "groups." .. group.id .. ".missing_rules")
        else
            for rule_index, raw_rule in ipairs(raw_group.rules) do
                local rule = compile_rule(raw_rule, group, defaults, errors, rule_index)
                if rule.stable_key ~= nil then
                    local previous_group = key_groups[rule.stable_key]
                    if previous_group == group.id then
                        add_error(errors, "duplicate_stable_key_in_group." .. group.id .. "." .. rule.stable_key)
                    elseif previous_group ~= nil then
                        warnings[#warnings + 1] = "duplicate_stable_key_across_groups."
                            .. rule.stable_key .. "." .. previous_group .. "." .. group.id
                    end
                    if by_key[rule.stable_key] == nil and rule.enabled then
                        by_key[rule.stable_key] = rule
                    end
                    key_groups[rule.stable_key] = previous_group or group.id
                end
                rules[#rules + 1] = rule
            end
        end
    end

    return {
        enabled = config.enabled == true and #errors == 0,
        valid = #errors == 0,
        errors = errors,
        warnings = warnings,
        rules = rules,
        by_key = by_key
    }
end

-- 按稳定键查找规则；返回值只读，Hook 不创建候选副本。
function RuleSet.find(compiled, event_id, trigger_id)
    if not compiled or not compiled.enabled then return nil end
    local event_text = normalize_uint(event_id)
    local trigger_text = normalize_uint(trigger_id)
    if not event_text or not trigger_text then return nil end
    local rule = compiled.by_key[event_text .. ":" .. trigger_text]
    return rule and rule.enabled and rule or nil
end

-- 使用 [0, 1) 的调用方随机值选择候选；边界值被限制以避免浮点溢出到数组末尾之外。
function RuleSet.select_candidate(rule, random_value)
    if not rule or rule.total_weight <= 0 then return nil end
    local value = tonumber(random_value) or 0
    if value < 0 then value = 0 end
    if value >= 1 then value = 0.999999999 end
    local target = value * rule.total_weight
    local cumulative = 0
    for _, candidate in ipairs(rule.candidates) do
        cumulative = cumulative + candidate.weight
        if target < cumulative then return candidate end
    end
    return rule.candidates[#rule.candidates]
end

-- 获取一次播放占用；同时执行冷却和并发门控，成功时返回令牌与候选。
function RuleSet.acquire(rule, now_ms, random_value)
    if not rule or not rule.enabled then return nil, "disabled" end
    now_ms = tonumber(now_ms) or 0
    if rule.last_trigger_ms ~= nil and now_ms - rule.last_trigger_ms < rule.cooldown_ms then
        return nil, "cooldown"
    end
    if rule.active_count >= rule.max_concurrent then return nil, "concurrency" end
    local candidate = RuleSet.select_candidate(rule, random_value)
    if not candidate then return nil, "no_candidate" end
    rule.last_trigger_ms = now_ms
    rule.active_count = rule.active_count + 1
    rule.next_token_id = rule.next_token_id + 1
    local token = {
        id = rule.next_token_id,
        rule = rule,
        candidate = candidate,
        expires_at = now_ms + (candidate.max_duration_ms > 0
            and candidate.max_duration_ms or DEFAULT_TOKEN_LEASE_MS)
    }
    rule.active_tokens[token.id] = token
    return token, "accepted"
end

-- 释放播放占用令牌；重复释放和跨规则令牌不会破坏计数。
function RuleSet.release(token)
    if type(token) ~= "table" or type(token.rule) ~= "table" then return false end
    local rule = token.rule
    if rule.active_tokens[token.id] ~= token or rule.active_count <= 0 then return false end
    rule.active_tokens[token.id] = nil
    rule.active_count = rule.active_count - 1
    token.rule = nil
    token.candidate = nil
    return true
end

-- 按候选最大时长回收未收到后端完成通知的令牌；返回本次回收数量。
function RuleSet.expire(rule, now_ms)
    if not rule then return 0 end
    now_ms = tonumber(now_ms) or 0
    local expired = 0
    for _, token in pairs(rule.active_tokens) do
        if token.expires_at ~= nil and now_ms >= token.expires_at then
            if RuleSet.release(token) then expired = expired + 1 end
        end
    end
    return expired
end

return RuleSet
