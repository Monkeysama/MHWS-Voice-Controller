-- VoiceController 替换规则运行时适配层。
-- 帧线程负责编译与预检；Hook 线程只调用 match/dispatch 并向外部音频内存队列入队，不拥有文件或音频资源。

local RuleEngine = require("VoiceController/VoiceControllerRuleEngine")
local RuleSet = require("VoiceController/VoiceControllerRuleSet")

local Runtime = {}

local function unique_files(compiled)
    local files = {}
    local seen = {}
    if compiled.kind == "v1" then
        local file = compiled.rule.file
        if file then files[1] = file end
    else
        for _, rule in ipairs(compiled.rule_set.rules) do
            for _, candidate in ipairs(rule.candidates) do
                if candidate.file and not seen[candidate.file] then
                    seen[candidate.file] = true
                    files[#files + 1] = candidate.file
                end
            end
        end
    end
    return files
end

-- 编译 v1 或 v2 配置；非法配置保持禁用并携带原始诊断。
function Runtime.compile(config)
    config = type(config) == "table" and config or {}
    if config.schemaVersion == 2 then
        local rule_set = RuleSet.compile(config)
        return {
            kind = "v2",
            valid = rule_set.valid,
            enabled = rule_set.enabled,
            errors = rule_set.errors,
            rule_set = rule_set,
            preflight = {}
        }
    end
    local rule = RuleEngine.compile(config)
    return {
        kind = "v1",
        valid = rule.valid,
        enabled = rule.enabled,
        errors = rule.errors,
        rule = rule,
        preflight = {}
    }
end

-- 帧线程预检所有去重后的候选文件；check_fn(path) 返回 ready,error。
function Runtime.refresh_preflight(compiled, check_fn)
    if not compiled or type(check_fn) ~= "function" then return false end
    local all_ready = true
    local next_preflight = {}
    for _, file in ipairs(unique_files(compiled)) do
        local ready, err = check_fn(file)
        next_preflight[file] = {ready = ready == true, error = err}
        if not ready then all_ready = false end
    end
    compiled.preflight = next_preflight
    return all_ready
end

local function find_rule(compiled, event_id, trigger_id)
    if not compiled or not compiled.enabled then return nil end
    if compiled.kind == "v2" then
        return RuleSet.find(compiled.rule_set, event_id, trigger_id)
    end
    if RuleEngine.match(compiled.rule, event_id, trigger_id) then return compiled.rule end
    return nil
end

local function candidate_for_v1(rule)
    return {
        file = rule.file,
        volume = rule.volume,
        speed = rule.speed,
        max_duration_ms = rule.max_duration_ms
    }
end

-- Hook 线程执行匹配、冷却/并发门控和入队；入队失败会立即归还 v2 并发令牌。
function Runtime.dispatch(compiled, event_id, trigger_id, now_ms, random_value, enqueue_fn)
    local rule = find_rule(compiled, event_id, trigger_id)
    if not rule then return {matched = false} end
    if rule.mode == "observe" then
        return {matched = true, mode = "observe", reason = "observe", rule = rule}
    end

    local token = nil
    local candidate = nil
    local reason = nil
    if compiled.kind == "v2" then
        candidate = RuleSet.select_candidate(rule, random_value)
    else
        candidate = candidate_for_v1(rule)
    end

    local preflight = candidate and compiled.preflight[candidate.file] or nil
    if not preflight or not preflight.ready then
        return {
            matched = true,
            mode = rule.mode,
            reason = "fallback_" .. tostring(preflight and preflight.error or "not_ready"),
            rule = rule,
            candidate = candidate
        }
    end

    if compiled.kind == "v2" then
        token, reason = RuleSet.acquire(rule, now_ms, random_value)
        if not token then
            return {matched = true, mode = rule.mode, reason = reason, rule = rule}
        end
        candidate = token.candidate
    else
        local accepted
        accepted, reason = RuleEngine.accept(rule, now_ms)
        if not accepted then
            return {matched = true, mode = rule.mode, reason = reason, rule = rule}
        end
    end

    local spec = {
        stable_key = rule.stable_key,
        file = candidate.file,
        volume = candidate.volume,
        speed = candidate.speed,
        max_duration_ms = candidate.max_duration_ms,
        group_id = rule.group_id,
        rule_id = rule.id,
        token = token
    }
    local queued = type(enqueue_fn) == "function" and enqueue_fn(spec) == true
    if not queued and token then RuleSet.release(token) end
    return {
        matched = true,
        mode = rule.mode,
        reason = queued and rule.mode or "queue_full",
        queued = queued,
        rule = rule,
        candidate = candidate,
        token = queued and token or nil,
        spec = spec
    }
end

-- 帧线程按最大时长回收 v2 并发令牌；后续可由真实通道完成通知提前释放。
function Runtime.expire(compiled, now_ms)
    if not compiled or compiled.kind ~= "v2" then return 0 end
    local expired = 0
    for _, rule in ipairs(compiled.rule_set.rules) do
        expired = expired + RuleSet.expire(rule, now_ms)
    end
    return expired
end

-- 帧线程判断是否存在需要外部音频的启用规则，兼容 v2 的规则级 mode 覆盖。
function Runtime.requires_preflight(compiled)
    if not compiled or not compiled.enabled then return false end
    if compiled.kind == "v1" then return compiled.rule.mode ~= "observe" end
    for _, rule in ipairs(compiled.rule_set.rules) do
        if rule.enabled and rule.mode ~= "observe" then return true end
    end
    return false
end

function Runtime.summary(compiled)
    if not compiled then return {kind = "none", valid = false, enabled = false, ruleCount = 0} end
    return {
        kind = compiled.kind,
        valid = compiled.valid,
        enabled = compiled.enabled,
        ruleCount = compiled.kind == "v2" and #compiled.rule_set.rules or 1,
        errors = compiled.errors
    }
end

return Runtime
