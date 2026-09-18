-- VoiceController REFF 服务。
-- 在 REFF 的 UpdateBehavior 调度线程响应网页请求；服务不拥有 Hook 或音频资源，只读取快照并调用配置事务。

local ConfigManager = require("VoiceController/VoiceControllerConfigManager")

local Service = {}

local PLUGIN_ID = "voice-controller"
local CHANGE_EVENT = "voice-controller.changed"

local function mutation_error(result)
    if type(result) == "table" then return table.concat(result, ", ") end
    return tostring(result or "operation_failed")
end

local function require_string(params, name)
    local value = type(params) == "table" and params[name] or nil
    assert(type(value) == "string" and value ~= "", name .. " is required")
    return value
end

-- 注册 REFF 插件方法；依赖可注入以便纯 Lua 测试，正式环境使用全局桥接和 reff.sdk。
function Service.register(api, dependencies)
    assert(type(api) == "table", "service api is required")
    dependencies = dependencies or {}
    local native = dependencies.native or rawget(_G, "reff_native")
    if native == nil then return nil, "reff_native_unavailable" end
    local sdk = dependencies.sdk or require("reff.sdk")
    local codec = dependencies.json or json
    local handle = nil

    local function get_manager()
        local manager = api.get_config_manager()
        assert(manager ~= nil, api.get_config_manager_error() or "config_editor_unavailable")
        return manager
    end

    -- 生成浏览器可序列化状态；近期事件限制为最后 120 条，避免网页轮询复制完整环形队列。
    local function snapshot()
        local manager = api.get_config_manager()
        local config = manager and ConfigManager.snapshot(manager) or nil
        return {
            schemaVersion = 2,
            revision = manager and manager.revision or 0,
            status = api.get_status(),
            events = api.get_recent_events(),
            savedEvents = api.get_saved_events(),
            catalog = api.get_catalog(),
            config = config,
            -- 分组文件夹只推元数据与占用关系；规则体本身就在 config.groups 里。
            groupFolders = api.get_group_folders(),
            conflicts = api.get_conflicts(),
            folderRejects = api.get_group_rejects(),
            -- 目录名含非 ASCII 的分组：能玩但不能回写 group.json，界面要明确提示。
            unwritableFolders = api.get_unwritable_folders(),
            warnings = manager and ConfigManager.warnings(manager) or {},
            editor = {
                ready = manager ~= nil,
                dirty = manager and manager.dirty or false,
                lastError = api.get_config_manager_error()
            }
        }
    end

    local function changed()
        local value = snapshot()
        if handle then handle.emit(CHANGE_EVENT, value) end
        return value
    end

    local function mutate(operation)
        return function(params)
            local ok, result = operation(get_manager(), params or {})
            assert(ok, mutation_error(result))
            return changed()
        end
    end

    local methods = {
        ["voice-controller.get-state"] = snapshot,
        ["voice-controller.save-event"] = function(params)
            local saved, err = api.save_event(require_string(params or {}, "stableKey"))
            assert(saved, mutation_error(err))
            return changed()
        end,
        ["voice-controller.remove-saved-event"] = function(params)
            local removed, err = api.remove_saved_event(require_string(params or {}, "stableKey"))
            assert(removed, mutation_error(err))
            return changed()
        end,
        ["voice-controller.play-event"] = function(params)
            local queued, err = api.play_event(require_string(params or {}, "stableKey"))
            -- 描述符可能在网页轮询之间自然过期；此类试听失败不应让 REFF 请求变成 HandlerError。
            if not queued and mutation_error(err) ~= "replay_unavailable" then
                assert(queued, mutation_error(err))
            end
            return snapshot()
        end,
        ["voice-controller.add-group"] = function(params)
            local manager = get_manager()
            local added, group_id = ConfigManager.add_group(manager, require_string(params or {}, "name"))
            assert(added, mutation_error(group_id))
            local directory = ConfigManager.get_group_audio_directory(manager, group_id)
            local queued, queue_error = api.ensure_group_directory(directory)
            if not queued then ConfigManager.remove_group(manager, group_id) end
            assert(queued, mutation_error(queue_error))
            return changed()
        end,
        ["voice-controller.update-group"] = mutate(function(manager, params)
            return ConfigManager.update_group(manager, require_string(params, "groupId"), {
                name = params.name,
                enabled = params.enabled
            })
        end),
        ["voice-controller.update-blocked-sources"] = mutate(function(manager, params)
            return ConfigManager.set_blocked_source_prefixes(manager, params.prefixes)
        end),
        ["voice-controller.remove-group"] = mutate(function(manager, params)
            return ConfigManager.remove_group(manager, require_string(params, "groupId"))
        end),
        ["voice-controller.add-rule-from-saved"] = mutate(function(manager, params)
            local stable_key = require_string(params, "stableKey")
            local event = api.get_saved_event(stable_key)
            assert(event ~= nil, "saved_event_not_found")
            return ConfigManager.add_rule_from_saved_event(
                manager, require_string(params, "groupId"), event,
                require_string(params, "file"))
        end),
        ["voice-controller.update-rule"] = mutate(function(manager, params)
            return ConfigManager.update_rule(
                manager, require_string(params, "groupId"), require_string(params, "ruleId"), {
                    enabled = params.enabled,
                    mode = params.mode,
                    replace_strategy = params.replaceStrategy,
                    cooldown_ms = params.cooldownMs,
                    max_concurrent = params.maxConcurrent
                })
        end),
        ["voice-controller.remove-rule"] = mutate(function(manager, params)
            return ConfigManager.remove_rule(
                manager, require_string(params, "groupId"), require_string(params, "ruleId"))
        end),
        ["voice-controller.add-candidate"] = mutate(function(manager, params)
            return ConfigManager.add_candidate(
                manager, require_string(params, "groupId"), require_string(params, "ruleId"),
                require_string(params, "file"), {
                    weight = params.weight,
                    volume = params.volume,
                    speed = params.speed,
                    max_duration_ms = params.maxDurationMs
                })
        end),
        ["voice-controller.update-candidate"] = mutate(function(manager, params)
            return ConfigManager.update_candidate(
                manager, require_string(params, "groupId"), require_string(params, "ruleId"),
                assert(tonumber(params.candidateIndex), "candidateIndex is required"), {
                    file = params.file,
                    weight = params.weight,
                    volume = params.volume,
                    speed = params.speed,
                    max_duration_ms = params.maxDurationMs
                })
        end),
        ["voice-controller.remove-candidate"] = mutate(function(manager, params)
            return ConfigManager.remove_candidate(
                manager, require_string(params, "groupId"), require_string(params, "ruleId"),
                assert(tonumber(params.candidateIndex), "candidateIndex is required"))
        end),
        ["voice-controller.test-candidate"] = function(params)
            params = params or {}
            local queued, err = api.test_candidate(
                get_manager(), require_string(params, "groupId"), require_string(params, "ruleId"),
                assert(tonumber(params.candidateIndex), "candidateIndex is required"))
            assert(queued, mutation_error(err))
            return snapshot()
        end,
        ["voice-controller.save"] = function()
            local manager = get_manager()
            local saved, err = api.save_config(manager)
            assert(saved, tostring(err or "save_failed"))
            return changed()
        end
    }

    local sdk_native = {
        is_ready = native.is_ready,
        emit = function(plugin_id, event_name, payload)
            return native.emit(plugin_id, event_name, codec.dump_string(payload))
        end
    }
    handle = sdk.register(PLUGIN_ID, {methods = methods, events = {CHANGE_EVENT}}, sdk_native)
    return handle
end

return Service
