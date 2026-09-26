-- VoiceController 分组规则集。
-- 由帧线程编译配置，Hook 线程只读取编译结果；规则对象拥有冷却和并发计数，音频资源仍由 REFAudio 工作线程拥有。

local RuleSet = {}
local ActionContext = require("VoiceController/VoiceControllerActionContext")

local MAX_CONCURRENT = 32
local DEFAULT_VOLUME = 1.5
local MAX_VOLUME = 5.0
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
    local action = candidate.action ~= nil and ActionContext.normalize(candidate.action) or nil
    if candidate.action ~= nil and action == nil then add_error(errors, label .. ".invalid_action") end
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
        action = action,
        action_key = ActionContext.key(action),
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
    local action = raw_rule.action ~= nil and ActionContext.normalize(raw_rule.action) or nil
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
    if raw_rule.action ~= nil and action == nil then add_error(errors, label .. ".invalid_action") end
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
        -- 旧配置的规则级动作在编译阶段映射为候选动作，不依赖编辑器保存才能运行。
        if compiled.action == nil and action ~= nil then
            compiled.action = action
            compiled.action_key = ActionContext.key(action)
        end
        candidates[#candidates + 1] = compiled
        total_weight = total_weight + compiled.weight
    end
    if total_weight <= 0 then add_error(errors, label .. ".zero_total_weight") end

    local stable_key = event_id and trigger_id and (event_id .. ":" .. trigger_id) or nil
    return {
        id = tostring(raw_rule.id or (group.id .. ":" .. tostring(index))),
        group_id = group.id,
        enabled = raw_rule.enabled ~= false and group.enabled,
        event_id = event_id,
        trigger_id = trigger_id,
        stable_key = stable_key,
        action = action,
        action_key = ActionContext.key(action),
        match_key = stable_key and ActionContext.rule_key(stable_key, action) or nil,
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
        volume = bounded_number(config.volume, DEFAULT_VOLUME, 0.0, MAX_VOLUME) or DEFAULT_VOLUME,
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
    local by_stable = {}
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
                if rule.match_key ~= nil then
                    -- 同组一个游戏音频只有一条规则；不同分组只有候选动作重叠才发占用告警。
                    local seen_group_key = group.id .. "/" .. rule.match_key
                    if key_groups[seen_group_key] then
                        add_error(errors, "duplicate_rule_match_in_group." .. group.id .. "." .. rule.stable_key)
                    end
                    key_groups[seen_group_key] = group.id
                    local scopes = {}
                    for _, candidate in ipairs(rule.candidates) do
                        scopes[ActionContext.rule_key(rule.stable_key, candidate.action)] = true
                    end
                    for scope in pairs(scopes) do
                        local previous_group = key_groups[scope]
                        if previous_group ~= nil and previous_group ~= group.id then
                            warnings[#warnings + 1] = "duplicate_rule_match_across_groups."
                                .. scope .. "." .. previous_group .. "." .. group.id
                        end
                        key_groups[scope] = previous_group or group.id
                    end
                    if by_key[rule.match_key] == nil and rule.enabled then
                        by_key[rule.match_key] = rule
                    end
                end
                rules[#rules + 1] = rule
                if rule.stable_key ~= nil and rule.enabled then
                    local bucket = by_stable[rule.stable_key]
                    if not bucket then bucket = {}; by_stable[rule.stable_key] = bucket end
                    bucket[#bucket + 1] = rule
                end
            end
        end
    end

    return {
        enabled = config.enabled == true and #errors == 0,
        valid = #errors == 0,
        errors = errors,
        warnings = warnings,
        rules = rules,
        by_key = by_key,
        by_stable = by_stable
    }
end

-- 顺序扫描已编译规则：精确动作候选优先于通配，组和规则原有顺序保持不变。
function RuleSet.find(compiled, event_id, trigger_id, observed_actions)
    if not compiled or not compiled.enabled then return nil end
    local event_text = normalize_uint(event_id)
    local trigger_text = normalize_uint(trigger_id)
    if not event_text or not trigger_text then return nil end
    local stable_key = event_text .. ":" .. trigger_text
    local observed = {}
    for _, action in ipairs(ActionContext.normalize_list(observed_actions)) do
        observed[ActionContext.key(action)] = true
    end
    local fallback = nil
    for _, rule in ipairs(compiled.by_stable[stable_key] or {}) do
        if rule.enabled then
            for _, candidate in ipairs(rule.candidates) do
                if candidate.action_key ~= nil and observed[candidate.action_key] then
                    return rule
                end
                if candidate.action_key == nil and fallback == nil then fallback = rule end
            end
        end
    end
    return fallback
end

-- 判断指定游戏音频是否存在需要读取主动作的候选；用于关闭近期采集时保留动作绑定替换。
function RuleSet.needs_action_context(compiled, event_id, trigger_id)
    if not compiled then return false end
    local event_text = normalize_uint(event_id)
    local trigger_text = normalize_uint(trigger_id)
    if not event_text or not trigger_text then return false end
    local stable_key = event_text .. ":" .. trigger_text
    for _, rule in ipairs(compiled.by_stable[stable_key] or {}) do
        if rule.enabled then
            for _, candidate in ipairs(rule.candidates or {}) do
                if candidate.action_key ~= nil then return true end
            end
        end
    end
    return false
end

-- 根据本次动作筛选候选；精确动作优先，只有没有精确候选时才考虑所有动作候选。
local function eligible_candidates(rule, observed_actions)
    local observed = {}
    for _, action in ipairs(ActionContext.normalize_list(observed_actions)) do
        observed[ActionContext.key(action)] = true
    end
    local exact, wildcard = {}, {}
    for _, candidate in ipairs(rule.candidates or {}) do
        if candidate.action_key == nil then wildcard[#wildcard + 1] = candidate
        elseif observed[candidate.action_key] then exact[#exact + 1] = candidate end
    end
    return #exact > 0 and exact or wildcard
end

function RuleSet.has_eligible_candidate(rule, observed_actions)
    return #eligible_candidates(rule, observed_actions) > 0
end

-- 使用 [0, 1) 的调用方随机值在本次动作匹配的候选内加权选择。
function RuleSet.select_candidate(rule, random_value, observed_actions)
    if not rule then return nil end
    local candidates = eligible_candidates(rule, observed_actions)
    local total_weight = 0
    for _, candidate in ipairs(candidates) do total_weight = total_weight + candidate.weight end
    if total_weight <= 0 then return nil end
    local value = tonumber(random_value) or 0
    if value < 0 then value = 0 end
    if value >= 1 then value = 0.999999999 end
    local target, cumulative = value * total_weight, 0
    for _, candidate in ipairs(candidates) do
        cumulative = cumulative + candidate.weight
        if target < cumulative then return candidate end
    end
    return candidates[#candidates]
end

-- 获取一次播放占用；成功时返回令牌与候选，候选可由预检前已选定的实例传入。
function RuleSet.acquire(rule, now_ms, random_value, observed_actions, selected_candidate)
    if not rule or not rule.enabled then return nil, "disabled" end
    now_ms = tonumber(now_ms) or 0
    if rule.last_trigger_ms ~= nil and now_ms - rule.last_trigger_ms < rule.cooldown_ms then
        return nil, "cooldown"
    end
    if rule.active_count >= rule.max_concurrent then return nil, "concurrency" end
    local candidate = selected_candidate or RuleSet.select_candidate(rule, random_value, observed_actions)
    if not candidate then return nil, "no_candidate" end
    rule.last_trigger_ms = now_ms
    rule.active_count = rule.active_count + 1
    rule.next_token_id = rule.next_token_id + 1
    local token = {
        id = rule.next_token_id, rule = rule, candidate = candidate,
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
