-- VoiceController 动作上下文值对象。
-- 仅处理可序列化标量，不持有游戏对象；Hook、收藏存储和规则编译器共享同一规范化与键生成约定。

local ActionContext = {}

local function normalize_nonnegative_integer(value)
    local number = tonumber(value)
    if number == nil or number < 0 or number ~= math.floor(number) then return nil end
    return number
end

-- 规范化单个动作；控制器槽位参与身份，避免基础动作和子动作的相同编号互相误匹配。
function ActionContext.normalize(action)
    if type(action) ~= "table" then return nil end
    local controller_index = normalize_nonnegative_integer(action.controllerIndex)
    local category = normalize_nonnegative_integer(action.category)
    local index = normalize_nonnegative_integer(action.index)
    if controller_index == nil or category == nil or index == nil then return nil end
    local type_name = type(action.typeName) == "string" and action.typeName or nil
    if type_name == "" then type_name = nil end
    return {
        controllerIndex = controller_index,
        category = category,
        index = index,
        typeName = type_name
    }
end

function ActionContext.key(action)
    local normalized = ActionContext.normalize(action)
    if not normalized then return nil end
    return string.format("%d:%d:%d",
        normalized.controllerIndex, normalized.category, normalized.index)
end

-- 只保留主动作控制器的观察结果，去重并稳定排序；独立候选配置中的旧子动作约束不在此修改。
function ActionContext.normalize_list(actions)
    local result, seen = {}, {}
    for _, raw in ipairs(type(actions) == "table" and actions or {}) do
        local action = ActionContext.normalize(raw)
        local key = action and ActionContext.key(action) or nil
        if key and action.controllerIndex == 0 and not seen[key] then
            seen[key] = true
            result[#result + 1] = action
        end
    end
    table.sort(result, function(left, right)
        if left.controllerIndex ~= right.controllerIndex then
            return left.controllerIndex < right.controllerIndex
        end
        if left.category ~= right.category then return left.category < right.category end
        return left.index < right.index
    end)
    return result
end

-- 合并两次观察结果；返回的新数组不复用调用方表，changed 仅表示出现了新的动作身份。
function ActionContext.merge(existing, incoming)
    local result = ActionContext.normalize_list(existing)
    local seen = {}
    for _, action in ipairs(result) do seen[ActionContext.key(action)] = true end
    local changed = false
    for _, action in ipairs(ActionContext.normalize_list(incoming)) do
        local key = ActionContext.key(action)
        if not seen[key] then
            seen[key] = true
            result[#result + 1] = action
            changed = true
        else
            for _, current in ipairs(result) do
                if ActionContext.key(current) == key and not current.typeName and action.typeName then
                    current.typeName = action.typeName
                    changed = true
                    break
                end
            end
        end
    end
    return ActionContext.normalize_list(result), changed
end

function ActionContext.contains(actions, expected)
    local expected_key = ActionContext.key(expected)
    if not expected_key then return false end
    for _, action in ipairs(ActionContext.normalize_list(actions)) do
        if ActionContext.key(action) == expected_key then return true end
    end
    return false
end

-- 规则身份由音频键和可选动作组成；无动作条件继续表示兼容旧配置的通配规则。
function ActionContext.rule_key(stable_key, action)
    local action_key = ActionContext.key(action)
    return action_key and (tostring(stable_key) .. "@" .. action_key) or tostring(stable_key)
end

return ActionContext
