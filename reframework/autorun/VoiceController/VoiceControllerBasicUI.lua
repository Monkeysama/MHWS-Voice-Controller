-- VoiceController REFramework 基础面板。
-- 仅在 REFramework UI 线程绘制 REFF 连接状态与分组开关；不拥有配置、Hook 或音频资源。
-- 所有修改通过调用方提供的帧线程接口立即持久化，不能替代 REFF 的完整管理页面。

local BasicUI = {}

local function error_text(value)
    if type(value) == "table" then return table.concat(value, ", ") end
    return tostring(value or "operation_failed")
end

-- 注册轻量面板；依赖可注入，以便在纯 Lua 测试中验证交互和错误处理。
function BasicUI.register(api, dependencies)
    assert(type(api) == "table", "basic ui api is required")
    dependencies = dependencies or {}
    local host = dependencies.re or re
    local ui = dependencies.imgui or imgui
    if type(host) ~= "table" or type(host.on_draw_ui) ~= "function"
        or type(ui) ~= "table"
    then
        return false, "reframework_ui_unavailable"
    end

    local last_message = nil
    local last_message_is_error = false

    host.on_draw_ui(function()
        if not ui.tree_node("音频控制器/voice_controller##voice_controller_basic") then return end

        if api.is_reff_connected() then
            ui.text_colored("REFF：已连接/Connected", 0xFF60C060)
        else
            ui.text_colored("REFF：未连接/Not Connected", 0xFF40C0FF)
        end

        local groups, load_error = api.get_groups()
        if type(groups) ~= "table" then
            ui.text("分组列表暂不可用/Group List Unavailable" .. error_text(load_error))
        elseif #groups == 0 then
            ui.text("未检测到分组/No Groups Detected")
        else
            ui.text("分组/Groups")
            for _, group in ipairs(groups) do
                local id = tostring(group.id or "")
                local name = tostring(group.name or id)
                local changed, enabled = ui.checkbox(
                    name .. "##voice_controller_group_" .. id,
                    group.enabled == true)
                if changed then
                    local saved, save_error = api.set_group_enabled(id, enabled == true)
                    last_message_is_error = saved ~= true
                    if saved then
                        last_message = string.format("已%s：%s", enabled and "启用" or "禁用", name)
                    else
                        last_message = "保存失败/Save Failed：" .. error_text(save_error)
                    end
                end
            end
        end

        if last_message then
            if last_message_is_error and type(ui.text_colored) == "function" then
                ui.text_colored(last_message, 0xFF6060FF)
            else
                ui.text(last_message)
            end
        end
        ui.tree_pop()
    end)
    return true
end

return BasicUI
