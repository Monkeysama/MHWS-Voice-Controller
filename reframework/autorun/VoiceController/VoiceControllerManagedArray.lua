-- REFramework 托管数组读取适配。
-- 仅在调用线程读取前几个元素，不持有数组引用；字段返回的 REManagedObject 可能没有 SystemArray.get_elements 包装。
local ManagedArray = {}

-- 有界读取数组，返回连续 Lua 表中的 {index, value}；index 保留托管数组原有的零基下标。
function ManagedArray.read_bounded(array, limit)
    if array == nil then return nil, "array_nil" end
    limit = math.max(0, math.min(tonumber(limit) or 0, 64))
    if type(array) == "table" and array.get_elements == nil and array.get_size == nil
        and array.get_element == nil and array.call == nil then
        local result = {}
        for index, value in ipairs(array) do
            if index > limit then break end
            result[#result + 1] = {index = index - 1, value = value}
        end
        return result
    end
    local bulk_ok, elements = pcall(function() return array:get_elements() end)
    if bulk_ok and type(elements) == "table" then
        return ManagedArray.read_bounded(elements, limit)
    end

    -- 从字段读取的数组不一定被包装成 SystemArray；其 TDB 仍可调用 get_Length/get_Item。
    local size_ok, size = pcall(function() return array:get_size() end)
    if not size_ok or type(size) ~= "number" then
        size_ok, size = pcall(function() return array:call("get_Length") end)
    end
    if not size_ok or type(size) ~= "number" then
        return nil, "array_length_unavailable:" .. tostring(array)
    end
    local result = {}
    for index = 0, math.min(size, limit) - 1 do
        local value_ok, value = pcall(function() return array:get_element(index) end)
        if not value_ok then
            value_ok, value = pcall(function()
                return array:call("get_Item(System.Int32)", index)
            end)
        end
        if not value_ok then return nil, "array_item_unavailable:" .. tostring(array) end
        result[#result + 1] = {index = index, value = value}
    end
    return result
end

return ManagedArray
