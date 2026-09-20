-- VoiceController 音频入口探测器。
-- 在 REFramework Lua 线程观察自然音频事件；仅对精确匹配且替换音频已入队的请求执行配置的抑制策略。
-- 日志资源由本脚本独占写入，使用固定容量文本避免无限增长。

local VERSION = "audio-probe-v22"
local ROOT = "VoiceController\\"
local LOG = ROOT .. "audio_probe.log"
local MAX_LINES = 1200
local FLUSH_INTERVAL = 0.5
local SNAPSHOT_INTERVAL = 2.0
local RECENT_CAPACITY = 500
local RECENT_COALESCE_WINDOW_MS = 2000
local RUNTIME_ROOT = ROOT .. "runtime\\"
local REPLACEMENT_CONFIG = ROOT .. "replacement.json"
local SAVED_EVENTS_CONFIG = ROOT .. "saved_events.json"
local CONFIG_RELOAD_INTERVAL = 2.0
local GROUP_SCAN_INTERVAL = 5.0
local CATALOG_SCAN_INTERVAL = 10.0
local CATALOG_SNAPSHOT = RUNTIME_ROOT .. "audio_catalog.json"
local NATIVE_CATALOG = "REFAudio\\audio_catalog_utf8.txt"
local INVALID_REQUEST_ID = 4294967295
local CALLBACK_DURATION = 8
local CALLBACK_END_OF_EVENT = 1

local EventStore = require("VoiceController/VoiceControllerEventStore")
local SavedEventStore = require("VoiceController/VoiceControllerSavedEventStore")
local GameAudioReplay = require("VoiceController/VoiceControllerGameAudioReplay")
local AudioCatalog = require("VoiceController/VoiceControllerAudioCatalog")
local ConfigManager = require("VoiceController/VoiceControllerConfigManager")
local GroupStore = require("VoiceController/VoiceControllerGroupStore")
local REFAudioClient = require("VoiceController/VoiceControllerREFAudioClient")
local Utf8FileBridge = require("VoiceController/VoiceControllerUtf8FileBridge")
local ReplacementRuntime = require("VoiceController/VoiceControllerReplacementRuntime")
local VoiceControllerREFF = require("VoiceController/VoiceControllerREFF")

local lines = {}
local pending = {}
local recent_events = EventStore.new(RECENT_CAPACITY)
local browser_player_events = EventStore.new(120)
local browser_npc_events = EventStore.new(120)
local browser_otomo_events = EventStore.new(120)
local browser_weapon_events = EventStore.new(120)
local browser_unknown_events = EventStore.new(120)
local game_audio_replay = GameAudioReplay.new()
local saved_event_store = nil
local saved_event_error = nil
local last_flush = 0
local last_snapshot = 0
local next_sequence = 0
local total_captured = 0
local voice_captured = 0
local unknown_captured = 0
local dropped_pending = 0
local hook_installed = false
local request_hook_installed = false
local playing_pair_hook_installed = false
local duration_hook_installed = false
local end_event_hook_installed = false
local voice_index = {}
local voice_index_ready = false
local next_index_attempt = 0
local player_voice_container = nil
local player_voice_object = nil
local next_container_scan = 0
local scene_containers = {}
local scene_container_keys = {}
local scene_containers_ready = false
local scene_scan_root_key = nil
local scene_scan_retry_at = 0
local saved_source_names = {npc = {}, otomo = {}, player = {}, weapon = {}}
local saved_source_discovered = {npc = false, otomo = false}
local replacement_runtime = ReplacementRuntime.compile({})
local replacement_config = nil
local config_manager = nil
local config_manager_error = "config_not_loaded"
-- REFramework 的 io.open 按本机代码页解释路径，无法定位含中文的分组目录；
-- 原生 REFAudio 清单是严格 UTF-8 的权威来源，因此非 ASCII 路径的存在性判断只查清单。
local catalog_path_index = {}
local function file_exists_for_client(path)
    if type(path) ~= "string" then return false end
    if not GroupStore.is_ascii(path) then
        return catalog_path_index[string.lower(path)] == true
    end
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end
local replacement_client = REFAudioClient.new({file_exists = file_exists_for_client})
local next_config_reload = 0
local replacement_config_fingerprint = nil
local group_scan = nil
local group_signature = nil
local group_info = nil
local group_conflicts = {}
local group_rejects = {}
local group_scanned_at = nil
local next_group_scan = 0
local replacement_config_schema = 1
local replacement_mode = "observe"
local replacement_strategy = nil
local replacement_stable_key = nil
local replacement_rule_count = 0
local replacement_matched = 0
local replacement_cooldown_skipped = 0
local replacement_concurrency_skipped = 0
local replacement_tokens_expired = 0
local replacement_preflight_ready = false
local replacement_preflight_error = nil
local next_replacement_preflight = 0
local replacement_suppressed = 0
local replacement_suppress_failed = 0
local test_playback_requested = 0
local test_playback_submitted = 0
local test_playback_failed = 0
local return_probe_samples = 0
local last_return_probe = nil
local pending_stop_request_ids = {}
local request_stable_keys = {}
local request_playing_ids = {}
local playing_stable_keys = {}
local playing_started_at = {}
local pending_durations = {}
local duration_by_key = {}
local next_catalog_scan = 0
local catalog_ready = false
local catalog_count = 0
local catalog_error_count = 0
local catalog_last_error = nil
local catalog_scanned_at = nil
local catalog_signature = nil
local catalog_snapshot = nil
local blocked_source_prefixes = {"SoundLayerdRandomGenerator"}
local runtime_messages = {}

-- 登记当前场景中的声音容器；容器引用由重放模块持有，扫描只在帧线程低频执行。
local function register_scene_container(container, source_object)
    if container == nil then return end
    local key = nil
    local ok, address = pcall(container.get_address, container)
    if ok and address then key = tostring(address) end
    key = key or tostring(container)
    if scene_container_keys[key] then return end
    scene_container_keys[key] = true
    scene_containers[#scene_containers + 1] = {
        container = container,
        source_object = source_object,
        target_object = source_object
    }
end

-- 从 GameObject 组件和 Transform 子树收集 SoundContainer；失败的对象分支直接跳过。
local function scan_game_object(root, visited, depth)
    if root == nil or depth > 32 then return end
    local address_ok, address = pcall(root.get_address, root)
    local key = address_ok and address and tostring(address) or tostring(root)
    if visited[key] then return end
    visited[key] = true
    local components_ok, components = pcall(root.call, root, "get_Components")
    if components_ok and components then
        local elements_ok, elements = pcall(components.get_elements, components)
        for _, component in ipairs(elements_ok and elements or {}) do
            local type_ok, type_def = pcall(component.get_type_definition, component)
            local name_ok, full_name = false, nil
            if type_ok and type_def then name_ok, full_name = pcall(type_def.get_full_name, type_def) end
            if name_ok and tostring(full_name) == "soundlib.SoundContainer" then
                register_scene_container(component, root)
            end
        end
    end
    local transform_ok, transform = pcall(root.call, root, "get_Transform")
    if not transform_ok or not transform then return end
    local child_ok, child = pcall(transform.call, transform, "get_Child")
    while child_ok and child ~= nil do
        local object_ok, object = pcall(child.call, child, "get_GameObject")
        if object_ok and object then scan_game_object(object, visited, depth + 1) end
        local next_ok, next_transform = pcall(child.call, child, "get_Next")
        child_ok, child = next_ok, next_transform
    end
end

-- 只按永久收藏中的来源对象名寻找 NPC/坐骑，避免重载后扫描整个场景对象树。
local function discover_saved_source_containers(category)
    if saved_source_discovered[category] then return end
    local wanted = saved_source_names[category]
    local found = false
    local ready = false
    local function consider(object)
        if object == nil then return end
        local ok, name = pcall(object.call, object, "get_Name")
        if ok and wanted[tostring(name)] then
            scan_game_object(object, {}, 0)
            found = true
        end
    end
    if category == "npc" then
        pcall(function()
            local manager = sdk.get_managed_singleton("app.NpcManager")
            local list = manager and manager._NpcList
            local elements = list and list:get_elements()
            ready = elements ~= nil
            for _, info in ipairs(elements or {}) do
                if info then consider(info:call("get_Object")) end
            end
        end)
    elseif category == "otomo" then
        pcall(function()
            local manager = sdk.get_managed_singleton("app.OtomoManager")
            local controls = manager and manager:call("get_OtomoManagedControlList")
            local elements = controls and controls:get_elements()
            ready = elements ~= nil
            for _, control in ipairs(elements or {}) do
                if control then consider(control:call("get_OtomoFace")) end
            end
            local master = manager and manager:call("getMasterOtomoManagedControl")
            if master then consider(master:call("get_OtomoFace")) end
        end)
    end
    saved_source_discovered[category] = ready
    if found then GameAudioReplay.invalidate_resolution(game_audio_replay) end
end

-- 以玩家对象为根扫描当前场景；后续自然事件会继续登记 NPC/怪物等临时对象的容器。
local function scan_scene_containers(now)
    if now < next_container_scan or now < scene_scan_retry_at then return end
    local ok, root = pcall(function()
        local manager = sdk.get_managed_singleton("app.PlayerManager")
        local player = manager and manager:call("getMasterPlayer")
        return player and player:call("get_Object")
    end)
    if not ok or not root then
        scene_scan_retry_at = now + 5.0
        return
    end
    local address_ok, address = pcall(root.get_address, root)
    local root_key = address_ok and address and tostring(address) or tostring(root)
    if scene_containers_ready and scene_scan_root_key == root_key then return end
    next_container_scan = now + 0.5
    scan_game_object(root, {}, 0)
    scene_scan_root_key = root_key
    scene_containers_ready = #scene_containers > 0
    GameAudioReplay.invalidate_resolution(game_audio_replay)
end

-- 从当前场景容器重建持久收藏的重放描述；不依赖 EMV 手动触发，也不写入近期事件。
local function resolve_persistent_descriptor(stable_key, metadata)
    if type(metadata) ~= "table" then return nil end
    if metadata.category == "npc" or metadata.category == "otomo" then
        discover_saved_source_containers(metadata.category)
    end
    -- 玩家索引优先，避免多个容器拥有相同键时选到非玩家语音。
    if (metadata.category == "player" or metadata.category == "voice")
        and player_voice_container and player_voice_object
        and voice_index[stable_key] ~= nil
    then
        local descriptor = GameAudioReplay.describe_container(
            player_voice_container, player_voice_object, player_voice_object, stable_key, metadata)
        if descriptor then return descriptor end
    end
    local wanted_source = type(metadata.sourceObject) == "string"
        and string.match(metadata.sourceObject, "^([^%[]+)") or nil
    local function try_entry(entry)
        if wanted_source and entry.source_object then
            local ok, name = pcall(entry.source_object.call, entry.source_object, "get_Name")
            if not ok or tostring(name) ~= tostring(wanted_source) then return nil end
        end
        return GameAudioReplay.describe_container(
            entry.container, entry.source_object, entry.target_object, stable_key, metadata)
    end
    if wanted_source then
        for _, entry in ipairs(scene_containers) do
            local descriptor = try_entry(entry)
            if descriptor then return descriptor end
        end
    end
    for _, entry in ipairs(scene_containers) do
        local descriptor = GameAudioReplay.describe_container(
            entry.container, entry.source_object, entry.target_object, stable_key, metadata)
        if descriptor then return descriptor end
    end
    return nil
end

game_audio_replay.resolve_descriptor = resolve_persistent_descriptor

-- 帧线程写入有界运行时消息队列；Hook 只入队，不执行文件 IO。
local function queue_runtime_message(message)
    if #runtime_messages < 64 then runtime_messages[#runtime_messages + 1] = message end
end

-- 帧线程加载永久收藏；文件损坏只影响收藏页面，不阻断自然音频捕获。
local function load_saved_events()
    local store, err = SavedEventStore.load(SAVED_EVENTS_CONFIG)
    saved_event_store = store
    saved_event_error = err
    if store then
        for _, event in ipairs(SavedEventStore.snapshot(store)) do
            local category = event.category
            local source = type(event.sourceObject) == "string"
                and string.match(event.sourceObject, "^([^%[]+)") or nil
            if source and saved_source_names[category] then
                saved_source_names[category][source] = true
            end
        end
    end
    if err then queue_runtime_message("SAVED_EVENTS_LOAD_FAILED\treason=" .. tostring(err)) end
end

load_saved_events()

local function config_fingerprint(config)
    local function encode(value, seen)
        local value_type = type(value)
        if value_type ~= "table" then return value_type .. ":" .. tostring(value) end
        if seen[value] then return "cycle" end
        seen[value] = true
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = encode(key, seen) .. "=" .. encode(value[key], seen)
        end
        seen[value] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    if type(config) ~= "table" then return "invalid" end
    return encode(config, {})
end

-- 帧线程返回已经完成的权威目录扫描。nil 表示尚未扫描，不能据此删除任何旧配置；
-- 有音频缺失告警的目录仍然存在，必须保留并在编辑器中提示，不能误判成已删除。
local function importable_group_folders()
    return group_scan and group_scan.groups or nil
end

-- 返回确认存在的全部目录，包含因 group.json 无效而进入 rejects 的目录。
local function present_group_folders()
    if not group_scan then return nil end
    local result, seen = {}, {}
    local function add(value)
        local folder = GroupStore.normalize_folder(value)
        local key = folder and string.lower(folder) or nil
        if key and not seen[key] then
            seen[key] = true
            result[#result + 1] = folder
        end
    end
    for _, entry in ipairs(group_scan.groups or {}) do add(entry.folder) end
    for _, entry in ipairs(group_scan.rejects or {}) do add(entry.id) end
    return result
end

-- 帧线程根据磁盘配置和内存目录快照重建编辑会话；编辑器不共享运行时编译对象。
local function rebuild_config_manager()
    if type(replacement_config) ~= "table" then
        config_manager = nil
        config_manager_error = "config_not_loaded"
        return false
    end
    if type(catalog_snapshot) ~= "table" or not catalog_ready then
        config_manager = nil
        config_manager_error = "catalog_not_ready"
        return false
    end
    local manager, errors = ConfigManager.new(
        replacement_config, catalog_snapshot, importable_group_folders(), present_group_folders())
    if not manager then
        config_manager = nil
        config_manager_error = table.concat(errors or {"config_editor_invalid"}, ",")
        return false
    end
    -- 用户直接删除分组文件夹即表示卸载该分组；目录扫描确认后同步清理 replacement.json。
    -- 这里只回写主配置，不碰仍存在分组的 group.json，也允许原有缺失音频引用原样保留。
    if type(manager.removed_groups) == "table" and #manager.removed_groups > 0 then
        local saved, save_error = ConfigManager.save(manager, REPLACEMENT_CONFIG, {
            utf8_read = Utf8FileBridge.read,
            utf8_write = Utf8FileBridge.write,
            skip_manifests = true,
            allow_missing_files = true
        })
        if not saved then
            config_manager = manager
            config_manager_error = "stale_group_cleanup_failed." .. tostring(save_error)
            queue_runtime_message("GROUP_CLEANUP_FAILED\t" .. tostring(save_error))
            return false
        end
        local removed = {}
        for _, entry in ipairs(manager.removed_groups) do
            removed[#removed + 1] = tostring(entry.folder)
        end
        replacement_config = ConfigManager.snapshot(manager)
        replacement_config_fingerprint = nil
        next_config_reload = 0
        queue_runtime_message("GROUPS_REMOVED\tfolders=" .. table.concat(removed, ","))
    end
    config_manager = manager
    config_manager_error = nil
    return true
end

-- 帧线程把本地配置与检测到的分组文件夹合成一份有效配置，再编译给 Hook 使用。
-- group.json 只是分发载体：文件夹里新检测到的分组默认关闭，运行时配置仍以 replacement.json 为准。
-- 本函数不重建编辑器会话：文件夹变化不得丢弃用户未保存的编辑。
local function apply_runtime_config()
    local effective, info = GroupStore.compose(replacement_config or {}, group_scan)
    group_info = info
    group_conflicts = info.conflicts
    group_rejects = {}
    for _, reject in ipairs(group_scan and group_scan.rejects or {}) do
        group_rejects[#group_rejects + 1] = reject
    end
    for _, imported in ipairs(info.imported or {}) do
        queue_runtime_message("GROUP_IMPORTED\tfolder=" .. tostring(imported) .. "\tenabled=false")
    end

    replacement_runtime = ReplacementRuntime.compile(effective)
    local summary = ReplacementRuntime.summary(replacement_runtime)
    replacement_rule_count = summary.ruleCount or 0
    replacement_stable_key = replacement_runtime.kind == "v1"
        and replacement_runtime.rule.stable_key or nil
    next_replacement_preflight = 0

    if not replacement_runtime.valid then
        queue_runtime_message(
            "REPLACEMENT_CONFIG_INVALID\t" .. table.concat(replacement_runtime.errors, ","))
    end
    for _, conflict in ipairs(group_conflicts) do
        local winner = conflict.winner
            and (conflict.winner.group_id .. "/" .. conflict.winner.rule_id) or "none"
        local occupied = {}
        for _, loser in ipairs(conflict.losers) do
            occupied[#occupied + 1] = loser.group_id .. "/" .. loser.rule_id
                .. (loser.enabled and "!" or "-")
        end
        queue_runtime_message(string.format("GROUP_CONFLICT\tkey=%s\tactive=%s\toccupied=%s",
            conflict.stableKey, winner, table.concat(occupied, ",")))
    end
end

-- 帧线程定期扫描 Groups 下的分组文件夹；文件夹或清单变化时才重新合成并编译。
local function scan_groups(now)
    if now < next_group_scan then return end
    next_group_scan = now + GROUP_SCAN_INTERVAL

    local catalog_index = {}
    if type(catalog_snapshot) == "table" and type(catalog_snapshot.files) == "table" then
        for _, entry in ipairs(catalog_snapshot.files) do
            if type(entry) == "table" and entry.file then
                catalog_index[string.lower(entry.file)] = entry.file
            end
        end
    end
    local glob_fn = fs and type(fs.glob) == "function" and function(pattern)
        return fs.glob(pattern)
    end or nil
    local read_fn = fs and type(fs.read) == "function" and function(path)
        return fs.read(path)
    end or nil

    local scan = GroupStore.scan({
        glob = glob_fn,
        read = read_fn,
        decode = json.load_string,
        -- fs.glob 是 std::regex_match：模式必须是正则写法，见 GroupStore.SCAN_PATTERN。
        pattern = GroupStore.SCAN_PATTERN,
        catalog_files = catalog_snapshot and catalog_snapshot.files or nil,
        catalog_index = catalog_index
        ,utf8_read = Utf8FileBridge.read
    })
    -- 指纹只覆盖扫描内容：scannedAt 每次都变，若计入指纹会每轮都重编译并刷屏日志。
    local signature = GroupStore.canonical({groups = scan.groups, rejects = scan.rejects})
    if signature == group_signature then return end
    group_signature = signature
    scan.scannedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
    group_scan = scan
    group_scanned_at = scan.scannedAt

    local manifests = 0
    for _, entry in ipairs(scan.groups) do
        if entry.has_manifest then manifests = manifests + 1 end
    end
    queue_runtime_message(string.format("GROUPS_SCANNED\tfolders=%d\tmanifests=%d\trejected=%d",
        #scan.groups, manifests, #scan.rejects))
    for _, reject in ipairs(scan.rejects) do
        queue_runtime_message(string.format("GROUP_REJECTED\tfolder=%s\treason=%s",
            tostring(reject.id), tostring(reject.code)))
    end
    apply_runtime_config()
    -- 新检测到的分组会改变可编辑列表；用户未保存的编辑优先，不能被覆盖。
    if config_manager == nil or not config_manager.dirty then rebuild_config_manager() end
end

-- 帧线程定期热加载本地配置；解析或校验失败时关闭外部播放并保留游戏原声。
local function reload_replacement_config(now)
    if now < next_config_reload then return end
    next_config_reload = now + CONFIG_RELOAD_INTERVAL

    local ok, config = pcall(json.load_file, REPLACEMENT_CONFIG)
    local loaded = ok and type(config) == "table"
    local fingerprint = loaded and config_fingerprint(config) or "load_failed"
    if fingerprint == replacement_config_fingerprint then return end
    replacement_config_fingerprint = fingerprint
    replacement_config = loaded and config or nil
    blocked_source_prefixes = loaded and type(config.blockedSourcePrefixes) == "table"
        and config.blockedSourcePrefixes or {"SoundLayerdRandomGenerator"}
    replacement_config_schema = loaded and tonumber(config.schemaVersion) or 0
    replacement_mode = loaded and tostring(config.mode or "observe") or "observe"
    replacement_strategy = loaded and config.replaceStrategy or nil

    apply_runtime_config()

    if replacement_runtime.valid then
        queue_runtime_message(string.format(
            "REPLACEMENT_CONFIG\tschema=%s\tenabled=%s\tmode=%s\trules=%s\tkey=%s",
            tostring(replacement_config_schema), tostring(replacement_runtime.enabled),
            replacement_mode, tostring(replacement_rule_count), replacement_stable_key or "multiple"))
    end
    -- 只有本地文件变化才重建编辑器会话；包变化不丢弃未保存的编辑。
    rebuild_config_manager()
end

-- 在脚本线程更新固定容量环形日志；调用方可一次提交多条，避免高频事件重复写完整文件。
local function append_many(messages)
    for _, message in ipairs(messages) do
        lines[#lines + 1] = os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\t" .. tostring(message)
    end
    while #lines > MAX_LINES do
        table.remove(lines, 1)
    end
    fs.write(LOG, table.concat(lines, "\n") .. "\n")
end

local function append(message)
    append_many({message})
end

local function is_blocked_source(source_object)
    local lowered = string.lower(tostring(source_object or ""))
    for _, prefix in ipairs(blocked_source_prefixes) do
        if string.sub(lowered, 1, #tostring(prefix)) == string.lower(tostring(prefix)) then return true end
    end
    return false
end

-- 根据来源对象优先区分 NPC/随从；其余命中语音资源索引的事件归为玩家。
local function classify_audio_event(source_path, source_object)
    local object_name = string.lower(tostring(source_object or ""))
    local path = string.lower(tostring(source_path or ""))
    if string.find(object_name, "otomo", 1, true) or string.find(path, "otomo", 1, true) then return "otomo" end
    if string.find(object_name, "npc", 1, true) or string.find(path, "npc", 1, true) then return "npc" end
    if string.find(object_name, "it", 1, true) then return "weapon" end
    if source_path ~= nil then return "player" end
    return "unknown"
end

-- 为自然请求追加 Wwise Duration 位；保留游戏原有回调标志，失败时不阻断原始播放。
local function enable_duration_callback(request)
    local ok, callback = pcall(request.call, request, "get_Callback")
    local value = ok and tonumber(callback) or nil
    if value == nil then return end
    if math.floor(value / CALLBACK_END_OF_EVENT) % 2 == 0 then value = value + CALLBACK_END_OF_EVENT end
    if math.floor(value / CALLBACK_DURATION) % 2 == 0 then value = value + CALLBACK_DURATION end
    pcall(request.call, request, "set_Callback", value)
end

-- 音频 Hook 的轻量入队；运行在游戏线程，只读取标量，不做文件 IO 或资源访问。
local function enqueue_request(request, origin)
    if request == nil then return end
    if GameAudioReplay.is_active(game_audio_replay) then return end
    if #pending >= 256 then
        dropped_pending = dropped_pending + 1
        return
    end

    local function read(name, fallback)
        local ok, value = pcall(request.call, request, name)
        if ok and value ~= nil then return tostring(value) end
        return fallback or "?"
    end

    local function read_value(name)
        local ok, value = pcall(request.call, request, name)
        return ok and value or nil
    end

    local function read_object(name)
        local ok, value = pcall(request.call, request, name)
        if not ok or value == nil then return "?" end
        local type_name = "?"
        local address = "?"
        local type_ok, type_def = pcall(value.get_type_definition, value)
        if type_ok and type_def then
            local name_ok, full_name = pcall(type_def.get_full_name, type_def)
            if name_ok and full_name then type_name = tostring(full_name) end
        end
        local address_ok, object_address = pcall(value.get_address, value)
        if address_ok and object_address then address = tostring(object_address) end
        return type_name .. "@" .. address
    end

    local function read_game_object(name)
        local ok, value = pcall(request.call, request, name)
        if not ok or value == nil then return "?" end
        local object_name = "?"
        local name_ok, result = pcall(value.call, value, "get_Name")
        if name_ok and result then object_name = tostring(result) end
        return object_name .. "[" .. read_object(name) .. "]"
    end

    local event_id = read("get_EventId")
    local trigger_id = read("get_TriggerId")
    local source_path = voice_index[event_id .. ":" .. trigger_id]
    local container = read_object("get_Container")
    local source_game_object = read_value("get_SrcGameObj")
    local target_game_object = read_value("get_TargetGameObj")
    local source_object = read_game_object("get_SrcGameObj")
    local target_object = read_game_object("get_TargetGameObj")
    if is_blocked_source(source_object) then return end
    local category = classify_audio_event(source_path, source_object)
    enable_duration_callback(request)
    next_sequence = next_sequence + 1
    local replayable = GameAudioReplay.capture(game_audio_replay, request)
    register_scene_container(read_value("get_Container"), read_value("get_SrcGameObj"))

    local replacement = nil
    local replacement_queued = false
    local matched_strategy = nil
    if origin == "SoundManager.postRequestInfo" then
        local dispatch = ReplacementRuntime.dispatch(
            replacement_runtime, event_id, trigger_id, os.clock() * 1000, math.random(),
            function(spec)
                -- Hook 只转交对象引用；坐标读取和距离计算延迟到音频帧线程。
                spec.source_object = source_game_object
                spec.listener_object = player_voice_object or target_game_object
                spec.distance_enabled = true
                return REFAudioClient.enqueue_load(replacement_client, spec)
            end)
        if dispatch.matched then
            replacement_matched = replacement_matched + 1
            replacement_queued = dispatch.queued == true
            matched_strategy = dispatch.rule and dispatch.rule.replace_strategy or nil
            replacement = {
                matched = true,
                mode = dispatch.mode,
                result = dispatch.reason,
                groupId = dispatch.rule and dispatch.rule.group_id or nil,
                ruleId = dispatch.rule and dispatch.rule.id or nil,
                file = dispatch.candidate and dispatch.candidate.file or nil
            }
            if dispatch.reason == "cooldown" then
                replacement_cooldown_skipped = replacement_cooldown_skipped + 1
            elseif dispatch.reason == "concurrency" then
                replacement_concurrency_skipped = replacement_concurrency_skipped + 1
            end
        end
    end

    local message = string.format(
        "EVENT\tOrigin=%s\tCategory=%s\tSourcePath=%s\tEventId=%s\tTriggerId=%s\tRequestId=%s\tPlayingId=%s\tGameObjId=%s\tPlaying=%s\tPositioned=%s\tContainer=%s\tSrcGameObj=%s\tTargetGameObj=%s",
        origin or "?",
        category, source_path or "?", event_id, trigger_id, read("get_RequestId"),
        read("get_PlayingId"), read("get_GameObjId"), read("get_Playing"),
        read("get_Positioned"), container, source_object, target_object)

    pending[#pending + 1] = {
        message = message,
        event = {
            sequence = next_sequence,
            stableKey = event_id .. ":" .. trigger_id,
            origin = origin or "?",
            category = category,
            pinned = category ~= "unknown",
            sourcePath = source_path or nil,
            eventId = event_id,
            triggerId = trigger_id,
            replacement = replacement,
            container = container,
            sourceObject = source_object,
            targetObject = target_object,
            offsetJointHash = tonumber(read("get_OffsetJointHash", "0")) or 0,
            replayable = replayable == true,
            durationMs = duration_by_key[event_id .. ":" .. trigger_id],
            observedAtMs = math.floor(os.clock() * 1000)
        }
    }
    return event_id .. ":" .. trigger_id, replacement and replacement.result or nil,
        replacement_queued, matched_strategy, replacement ~= nil
end

local function read_request_scalar(request, method_name)
    local ok, value = pcall(request.call, request, method_name)
    if ok and value ~= nil then return tostring(value) end
    return "?"
end

local function is_voice_path(path)
    if not path then return false end
    local lowered = string.lower(tostring(path))
    return string.find(lowered, "voice", 1, true) ~= nil
        or string.find(lowered, "npc", 1, true) ~= nil
        or string.find(lowered, "otomo", 1, true) ~= nil
        or string.find(lowered, "dialogue/dia_player", 1, true) ~= nil
        or string.find(lowered, "event/event_dia_player", 1, true) ~= nil
end

local voice_index_build_items = nil
local voice_index_build_cursor = 1
local voice_index_build_count = 0
local VOICE_INDEX_BATCH = 64

-- 在帧线程分批建立玩家语音 ID 索引；Hook 只读取已完成的表，不遍历托管集合。
local function try_build_voice_index()
    local now = os.clock()
    if voice_index_ready then return end
    if voice_index_build_items == nil then
        if now < next_index_attempt then return end
        next_index_attempt = now + 1.0
    end
    if voice_index_build_items == nil then
        local ok, items = pcall(function()
        local player_manager = sdk.get_managed_singleton("app.PlayerManager")
        local player = player_manager and player_manager:call("getMasterPlayer")
        local game_object = player and player:call("get_Object")
        local components = game_object and game_object:call("get_Components")
        local elements = components and components:get_elements()
        if not elements then return nil end

        local sound_container = nil
        for _, component in ipairs(elements) do
            local td = component and component:get_type_definition()
            if td and td:get_full_name() == "soundlib.SoundContainer" then
                sound_container = component
                break
            end
        end
        if not sound_container then return nil end

        player_voice_container = sound_container
        player_voice_object = game_object

        local list_data = sound_container:call("get_AllTriggerInfoListData")
        local items = list_data and list_data._items
        if not items then return nil end
        local snapshot = {}
        for _, data in pairs(items) do snapshot[#snapshot + 1] = data end
        return snapshot
        end)
        if not ok or type(items) ~= "table" or #items == 0 then return end
        voice_index_build_items = items
        voice_index_build_cursor = 1
        voice_index_build_count = 0
    end

    local processed = 0
    while voice_index_build_cursor <= #voice_index_build_items and processed < VOICE_INDEX_BATCH do
        local data = voice_index_build_items[voice_index_build_cursor]
        voice_index_build_cursor = voice_index_build_cursor + 1
        processed = processed + 1
        if data then
            local path = data:call("get_Path")
            if is_voice_path(path) then
                local trigger_array = data:call("get_TriggerInfoList")
                local triggers = trigger_array and trigger_array:get_elements()
                for _, trigger in ipairs(triggers or {}) do
                    local event_id = trigger:call("get_EventId")
                    local trigger_id = trigger:call("get_TriggerId")
                    if event_id and trigger_id
                        and event_id ~= 4294967295 and trigger_id ~= 4294967295
                    then
                        voice_index[tostring(event_id) .. ":" .. tostring(trigger_id)] = tostring(path)
                        voice_index_build_count = voice_index_build_count + 1
                    end
                end
            end
        end
    end
    if voice_index_build_cursor > #voice_index_build_items then
        local count = voice_index_build_count
        voice_index_build_items = nil
        voice_index_ready = true
        GameAudioReplay.invalidate_resolution(game_audio_replay)
        append("VOICE_INDEX_READY\tentries=" .. tostring(count))
    end
end

-- 帧线程低频扫描外部音频目录并写入规则管理快照；Hook 不读取目录，也不拥有扫描结果。
local function scan_audio_catalog(now)
    if now < next_catalog_scan then return end
    next_catalog_scan = now + CATALOG_SCAN_INTERVAL

    local captured_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local native_content = fs and type(fs.read) == "function" and fs.read(NATIVE_CATALOG) or nil
    local native_paths = AudioCatalog.parse_native_manifest(native_content)
    local snapshot
    if native_paths then
        snapshot = AudioCatalog.scan(function() return native_paths end, captured_at)
        snapshot.source = "refaudio_utf8"
    else
        snapshot = AudioCatalog.scan(function(pattern)
            if not fs or type(fs.glob) ~= "function" then error("fs.glob unavailable") end
            return fs.glob(pattern)
        end, captured_at)
        snapshot.source = "fs_glob"
    end
    catalog_count = snapshot.count
    catalog_error_count = #snapshot.errors
    catalog_last_error = snapshot.errors[1] and snapshot.errors[1].code or nil
    catalog_scanned_at = captured_at
    catalog_snapshot = snapshot
    -- 原生清单的路径是严格 UTF-8，可覆盖非 ASCII 分组目录；只重建索引，不改变快照语义。
    catalog_path_index = {}
    for _, entry in ipairs(snapshot.files or {}) do
        if type(entry) == "table" and type(entry.file) == "string" then
            catalog_path_index[string.lower(entry.file)] = true
        end
    end

    local write_ok, write_error = pcall(json.dump_file, CATALOG_SNAPSHOT, snapshot, 2)
    catalog_ready = write_ok and catalog_error_count == 0
    if not write_ok then
        catalog_error_count = catalog_error_count + 1
        catalog_last_error = "snapshot_write_failed: " .. tostring(write_error)
    end

    if catalog_ready then
        if config_manager then
            local updated, errors = ConfigManager.set_catalog(config_manager, snapshot)
            if updated then
                config_manager_error = nil
            else
                config_manager_error = table.concat(
                    errors or {"catalog_update_failed"}, ",")
            end
        else
            rebuild_config_manager()
        end
    else
        config_manager_error = catalog_last_error or "catalog_not_ready"
    end

    local signature = table.concat({
        tostring(catalog_ready), tostring(catalog_count),
        tostring(catalog_error_count), tostring(catalog_last_error)
    }, ":")
    if signature ~= catalog_signature then
        catalog_signature = signature
        -- 目录快照变化会影响包的音频告警与候选可用性，立即安排一次包扫描。
        next_group_scan = 0
        queue_runtime_message(string.format(
            "AUDIO_CATALOG\tready=%s\tfiles=%d\terrors=%d\tlastError=%s",
            tostring(catalog_ready), catalog_count, catalog_error_count,
            tostring(catalog_last_error or "none")))
    end
end

-- 在帧线程生成近期事件和诊断快照；JSON 文件只由本脚本拥有并定期整体替换。
local function write_runtime_snapshots(now)
    if now - last_snapshot < SNAPSHOT_INTERVAL then return end
    last_snapshot = now

    local captured_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    json.dump_file(RUNTIME_ROOT .. "recent.json", {
        schemaVersion = 2,
        capturedAt = captured_at,
        capacity = RECENT_CAPACITY,
        count = recent_events.size,
        totalCaptured = total_captured,
        events = EventStore.to_array(recent_events)
    }, 2)
    json.dump_file(RUNTIME_ROOT .. "diagnostics.json", {
        schemaVersion = 2,
        capturedAt = captured_at,
        mode = replacement_runtime.enabled and replacement_mode or "observe",
        hooks = {
            postRequestInfo = request_hook_installed,
            postEvent = hook_installed,
            playingIdPair = playing_pair_hook_installed
        },
        voiceIndexReady = voice_index_ready,
        totalCaptured = total_captured,
        voiceCaptured = voice_captured,
        unknownCaptured = unknown_captured,
        droppedPending = dropped_pending,
        recentCount = recent_events.size,
        audioCatalog = {
            ready = catalog_ready,
            count = catalog_count,
            errorCount = catalog_error_count,
            lastError = catalog_last_error,
            scannedAt = catalog_scanned_at,
            snapshot = CATALOG_SNAPSHOT
        },
        configEditor = {
            ready = config_manager ~= nil,
            dirty = config_manager and config_manager.dirty or false,
            revision = config_manager and config_manager.revision or 0,
            lastError = config_manager_error
        },
        replacement = {
            configSchema = replacement_config_schema,
            enabled = replacement_runtime.enabled,
            valid = replacement_runtime.valid,
            mode = replacement_mode,
            strategy = replacement_strategy,
            stableKey = replacement_stable_key,
            ruleCount = replacement_rule_count,
            matched = replacement_matched,
            cooldownSkipped = replacement_cooldown_skipped,
            concurrencySkipped = replacement_concurrency_skipped,
            tokensExpired = replacement_tokens_expired,
            preflightReady = replacement_preflight_ready,
            preflightError = replacement_preflight_error,
            suppressed = replacement_suppressed,
            suppressFailed = replacement_suppress_failed,
            pendingStops = (function()
                local count = 0
                for _ in pairs(pending_stop_request_ids) do count = count + 1 end
                return count
            end)(),
            audio = REFAudioClient.get_status(replacement_client),
            returnProbe = {
                supported = thread ~= nil and type(thread.get_hook_storage) == "function",
                samples = return_probe_samples,
                last = last_return_probe
            }
        },
        testPlayback = {
            requested = test_playback_requested,
            submitted = test_playback_submitted,
            failed = test_playback_failed
        },
        gameAudioReplay = GameAudioReplay.get_status(game_audio_replay),
        savedEvents = {
            ready = saved_event_store ~= nil,
            count = saved_event_store and #SavedEventStore.snapshot(saved_event_store) or 0,
            lastError = saved_event_error
        },
        groupFolders = {
            ready = group_scan ~= nil,
            scannedAt = group_scanned_at,
            count = group_scan and #group_scan.groups or 0,
            rejected = #group_rejects,
            unwritable = #GroupStore.unwritable_folders(
                replacement_config and replacement_config.groups),
            conflicts = #group_conflicts,
            rejects = #group_rejects > 0 and group_rejects or nil,
            lastError = group_rejects[1] and group_rejects[1].code or nil
        }
    }, 2)
end

-- 批量落盘在帧回调执行，避免音频 Hook 阻塞；控制消息最后写入，防止被同帧事件洪峰淘汰。
local function flush_pending()
    local now = os.clock()
    if now - last_flush >= FLUSH_INTERVAL and #pending > 0 then
        last_flush = now
        local messages = {}
        local captured_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        for _, entry in ipairs(pending) do
            entry.event.capturedAt = captured_at
            EventStore.push_coalesced(recent_events, entry.event, RECENT_COALESCE_WINDOW_MS)
            local browser_stores = {player = browser_player_events, npc = browser_npc_events,
                otomo = browser_otomo_events, weapon = browser_weapon_events, unknown = browser_unknown_events}
            local browser_store = browser_stores[entry.event.category] or browser_unknown_events
            -- 浏览器列表按稳定键聚合整个当前会话；类别窗口只限制不同稳定键的数量。
            EventStore.push_coalesced(browser_store, entry.event, math.huge)
            messages[#messages + 1] = entry.message
            total_captured = total_captured + 1
            if entry.event.category ~= "unknown" then
                voice_captured = voice_captured + 1
            else
                unknown_captured = unknown_captured + 1
            end
        end
        append_many(messages)
        pending = {}
    end
    if #pending_durations > 0 then
        local stores = {browser_player_events, browser_npc_events, browser_otomo_events,
            browser_weapon_events, browser_unknown_events}
        local remaining = {}
        for _, item in ipairs(pending_durations) do
            local stable_key = item.stable_key or playing_stable_keys[item.playing_id]
            if stable_key then
                local first_duration = duration_by_key[stable_key] == nil
                duration_by_key[stable_key] = item.duration_ms
                for _, store in ipairs(stores) do
                    local event = EventStore.find_latest(store, stable_key)
                    if event then event.durationMs = item.duration_ms end
                end
                if first_duration then
                    queue_runtime_message(string.format("AUDIO_DURATION\tkey=%s\tms=%d",
                        tostring(stable_key), item.duration_ms))
                end
                playing_stable_keys[item.playing_id] = nil
            elseif os.clock() < item.deadline then
                remaining[#remaining + 1] = item
            end
        end
        pending_durations = remaining
    end
    if #runtime_messages > 0 then
        append_many(runtime_messages)
        runtime_messages = {}
    end
    write_runtime_snapshots(now)
end

-- 帧线程清理未收到 PlayingId 映射的目标请求，避免跨场景残留并显式记录回退。
local function expire_pending_stops(now)
    for request_id, entry in pairs(pending_stop_request_ids) do
        if now >= entry.deadline then
            pending_stop_request_ids[request_id] = nil
            replacement_suppress_failed = replacement_suppress_failed + 1
            queue_runtime_message(string.format(
                "REPLACEMENT_STOP_TIMEOUT\tkey=%s\tRequestId=%s",
                tostring(entry.stable_key), tostring(request_id)))
        end
    end
end

local function type_exists(name)
    local ok, td = pcall(sdk.find_type_definition, name)
    if ok then return td end
    return nil
end

local function describe_type(name)
    local td = type_exists(name)
    if not td then
        append("TYPE_MISSING\t" .. name)
        return
    end

    append("TYPE\t" .. td:get_full_name())
    local ok, methods = pcall(td.get_methods, td)
    if not ok or not methods then
        append("METHODS_UNAVAILABLE\t" .. name)
        return
    end

    for _, method in ipairs(methods) do
        local method_name = method:get_name()
        local lowered = string.lower(method_name)
        if string.find(lowered, "play", 1, true)
            or string.find(lowered, "sound", 1, true)
            or string.find(lowered, "voice", 1, true)
            or string.find(lowered, "trigger", 1, true)
            or string.find(lowered, "event", 1, true)
            or string.find(lowered, "request", 1, true)
            or string.find(lowered, "stop", 1, true)
        then
            local params = ""
            local param_types = method:get_param_types()
            if param_types then
                for index, param_type in ipairs(param_types) do
                    if index > 1 then params = params .. "," end
                    params = params .. (param_type and param_type:get_full_name() or "?")
                end
            end
            local return_type = method:get_return_type()
            append(string.format("METHOD\t%s\tparams=%d\t(%s)\treturn=%s",
                method_name, method:get_num_params(), params,
                return_type and return_type:get_full_name() or "void"))
        end
    end
end

-- 只安装 soundlib.SoundManager.postEvent(RequestInfo) 的观察 Hook，永不跳过原调用。
local function install_observe_hook()
    if hook_installed then return end
    local td = type_exists("soundlib.SoundManager")
    if not td then
        append("HOOK_TYPE_MISSING\tsoundlib.SoundManager")
        return
    end

    local ok, methods = pcall(td.get_methods, td)
    if not ok or not methods then
        append("HOOK_METHODS_UNAVAILABLE\tsoundlib.SoundManager")
        return
    end

    for _, method in ipairs(methods) do
        if method:get_name() == "postEvent" then
            local param_types = method:get_param_types()
            if param_types and #param_types == 1
                and param_types[1]
                and param_types[1]:get_full_name() == "soundlib.SoundManager.RequestInfo"
            then
                local function on_pre(args)
                    local ok_request, request = pcall(sdk.to_managed_object, args[3])
                    if ok_request and request then enqueue_request(request, "SoundManager.postEvent") end
                end
                local hook_ok = pcall(sdk.hook, method, on_pre, function() end)
                if hook_ok then
                    hook_installed = true
                    append("HOOK_INSTALLED\tsoundlib.SoundManager.postEvent(RequestInfo)")
                else
                    append("HOOK_INSTALL_FAILED\tsoundlib.SoundManager.postEvent(RequestInfo)")
                end
                return
            end
        end
    end
    append("HOOK_OVERLOAD_NOT_FOUND\tsoundlib.SoundManager.postEvent(RequestInfo)")
end

-- Hook 自然 RequestInfo 入口；游戏线程只做精确匹配与内存入队，跳过原调用必须同时满足预检和入队条件。
local function install_post_request_info_hook()
    if request_hook_installed then return end
    local td = type_exists("soundlib.SoundManager")
    if not td then return end
    local ok, methods = pcall(td.get_methods, td)
    if not ok or not methods then return end

    for _, method in ipairs(methods) do
        local param_types = method:get_param_types()
        if method:get_name() == "postRequestInfo"
            and param_types and #param_types == 1
            and param_types[1]
            and param_types[1]:get_full_name() == "soundlib.SoundManager.RequestInfo"
        then
            local function on_pre(args)
                local storage = nil
                if thread ~= nil and type(thread.get_hook_storage) == "function" then
                    storage = thread.get_hook_storage()
                    storage.vc_return_probe = false
                    storage.vc_request = nil
                    storage.vc_stable_key = nil
                    storage.vc_duration_key = nil
                    storage.vc_request_id_before = nil
                    storage.vc_arm_stop = false
                    storage.vc_skip_original = false
                end

                local ok_request, request = pcall(sdk.to_managed_object, args[3])
                if not ok_request or not request then return end

                local stable_key, replacement_result, replacement_queued,
                    matched_strategy, replacement_matched_rule =
                    enqueue_request(request, "SoundManager.postRequestInfo")

                if storage == nil then return end
                storage.vc_return_probe = replacement_matched_rule == true
                storage.vc_duration_key = stable_key
                if storage.vc_return_probe then
                    storage.vc_stable_key = stable_key
                    storage.vc_request = request
                    storage.vc_request_id_before = read_request_scalar(request, "get_RequestId")
                    storage.vc_arm_stop = replacement_result == "replace"
                        and replacement_queued
                        and matched_strategy == "stop_playing_id"
                    storage.vc_skip_original = replacement_result == "replace"
                        and replacement_queued
                        and matched_strategy == "skip_original"
                end
                if storage.vc_skip_original then return sdk.PreHookResult.SKIP_ORIGINAL end
            end
            local function on_post(retval)
                if thread ~= nil and type(thread.get_hook_storage) == "function" then
                    local storage = thread.get_hook_storage()
                    if storage.vc_duration_key and storage.vc_skip_original ~= true then
                        local duration_ok, duration_request_id = pcall(sdk.to_int64, retval)
                        if duration_ok and duration_request_id ~= nil then
                            local request_key = tostring(duration_request_id)
                            request_stable_keys[request_key] = storage.vc_duration_key
                            if request_playing_ids[request_key] then
                                playing_stable_keys[request_playing_ids[request_key]] = storage.vc_duration_key
                                request_playing_ids[request_key] = nil
                            end
                        end
                    end
                    storage.vc_duration_key = nil
                    if storage.vc_return_probe then
                        local skipped_original = storage.vc_skip_original == true
                        local ok_return, return_value = false, nil
                        if not skipped_original then
                            ok_return, return_value = pcall(sdk.to_int64, retval)
                        end
                        local request = storage.vc_request
                        last_return_probe = {
                            stableKey = storage.vc_stable_key,
                            originalSkipped = skipped_original,
                            returnValue = skipped_original and tostring(INVALID_REQUEST_ID)
                                or (ok_return and tostring(return_value) or "?"),
                            requestIdBefore = storage.vc_request_id_before or "?",
                            requestIdAfter = read_request_scalar(request, "get_RequestId"),
                            playingIdAfter = read_request_scalar(request, "get_PlayingId"),
                            playingAfter = read_request_scalar(request, "get_Playing")
                        }
                        return_probe_samples = return_probe_samples + 1
                        queue_runtime_message(string.format(
                            "POST_REQUEST_RETURN\tkey=%s\tretval=%s\tRequestIdBefore=%s\tRequestIdAfter=%s\tPlayingIdAfter=%s\tPlayingAfter=%s",
                            tostring(last_return_probe.stableKey), tostring(last_return_probe.returnValue),
                            tostring(last_return_probe.requestIdBefore), tostring(last_return_probe.requestIdAfter),
                            tostring(last_return_probe.playingIdAfter), tostring(last_return_probe.playingAfter)))

                        if skipped_original then
                            replacement_suppressed = replacement_suppressed + 1
                            queue_runtime_message(string.format(
                                "REPLACEMENT_ORIGINAL_SKIPPED\tkey=%s\treturn=%s",
                                tostring(last_return_probe.stableKey), tostring(INVALID_REQUEST_ID)))
                        elseif storage.vc_arm_stop and ok_return and return_value ~= nil then
                            local request_id = tostring(return_value)
                            pending_stop_request_ids[request_id] = {
                                stable_key = last_return_probe.stableKey,
                                deadline = os.clock() + 2.0
                            }
                            queue_runtime_message(string.format(
                                "REPLACEMENT_STOP_ARMED\tkey=%s\tRequestId=%s",
                                tostring(last_return_probe.stableKey), request_id))
                        elseif storage.vc_arm_stop then
                            replacement_suppress_failed = replacement_suppress_failed + 1
                            queue_runtime_message("REPLACEMENT_STOP_ARM_FAILED\tinvalid_return_value")
                        end
                        storage.vc_return_probe = false
                        storage.vc_request = nil
                        storage.vc_stable_key = nil
                        storage.vc_request_id_before = nil
                        storage.vc_arm_stop = false
                        storage.vc_skip_original = false
                        if skipped_original then return sdk.to_ptr(INVALID_REQUEST_ID) end
                    end
                end
                return retval
            end
            local hook_ok = pcall(sdk.hook, method, on_pre, on_post)
            if hook_ok then
                request_hook_installed = true
                append("HOOK_INSTALLED\tSoundManager.postRequestInfo(RequestInfo)")
            else
                append("HOOK_INSTALL_FAILED\tSoundManager.postRequestInfo(RequestInfo)")
            end
            return
        end
    end
    append("HOOK_OVERLOAD_NOT_FOUND\tSoundManager.postRequestInfo(RequestInfo)")
end

-- 在引擎发布 RequestId→PlayingId 映射时，仅停止已武装的目标播放实例；SendRequest 为引擎原生单例。
local function install_playing_pair_hook()
    if playing_pair_hook_installed then return end
    local manager_type = type_exists("soundlib.SoundManager")
    local send_type = type_exists("via.simplewwise.SendRequest")
    local send_request = sdk.get_native_singleton("via.simplewwise.SendRequest")
    if not manager_type or not send_type or not send_request then
        append("HOOK_DEPENDENCY_MISSING\tplaying-id-pair")
        return
    end

    local method = manager_type:get_method(
        "onPostedRequstIdPlayingIdPairThisFrame(System.UInt32, System.UInt32)")
    if not method then
        append("HOOK_OVERLOAD_NOT_FOUND\tSoundManager.onPostedRequstIdPlayingIdPairThisFrame")
        return
    end

    local function on_pre(args)
        local request_ok, request_id = pcall(sdk.to_int64, args[3])
        local playing_ok, playing_id = pcall(sdk.to_int64, args[4])
        if not request_ok or not playing_ok then return end
        local request_key = tostring(request_id)
        local playing_key = tostring(playing_id)
        request_playing_ids[request_key] = playing_key
        playing_started_at[playing_key] = os.clock()
        if request_stable_keys[request_key] then
            playing_stable_keys[playing_key] = request_stable_keys[request_key]
            request_stable_keys[request_key] = nil
            request_playing_ids[request_key] = nil
        end
        local armed = pending_stop_request_ids[request_key]
        if not armed then return end
        pending_stop_request_ids[request_key] = nil

        local stop_ok, stop_result = pcall(
            sdk.call_native_func, send_request, send_type,
            "stopPlayingId(System.UInt32, System.UInt32)", tonumber(playing_id), 0)
        if stop_ok then
            replacement_suppressed = replacement_suppressed + 1
            queue_runtime_message(string.format(
                "REPLACEMENT_STOP_SUBMITTED\tkey=%s\tRequestId=%s\tPlayingId=%s\tresult=%s",
                tostring(armed.stable_key), request_key, tostring(playing_id), tostring(stop_result)))
        else
            replacement_suppress_failed = replacement_suppress_failed + 1
            queue_runtime_message(string.format(
                "REPLACEMENT_STOP_FAILED\tkey=%s\tRequestId=%s\tPlayingId=%s",
                tostring(armed.stable_key), request_key, tostring(playing_id)))
        end
    end

    local hook_ok = pcall(sdk.hook, method, on_pre, function() end)
    if hook_ok then
        playing_pair_hook_installed = true
        append("HOOK_INSTALLED\tSoundManager.onPostedRequstIdPlayingIdPairThisFrame(UInt32,UInt32)")
    else
        append("HOOK_INSTALL_FAILED\tSoundManager.onPostedRequstIdPlayingIdPairThisFrame")
    end
end

-- Hook Wwise 时长回调；游戏线程只提取 PlayingId 与毫秒值并入队，帧线程负责更新事件列表。
local function install_duration_hook()
    if duration_hook_installed then return end
    local callback_type = type_exists("soundlib.SoundCallbackManager")
    if not callback_type then return end
    local method = callback_type:get_method("onDuration(via.simplewwise.DurationCallbackInfo)")
    if not method then
        append("HOOK_OVERLOAD_NOT_FOUND\tSoundCallbackManager.onDuration")
        return
    end
    local function on_pre(args)
        if #pending_durations >= 128 then return end
        local ok, info = pcall(sdk.to_managed_object, args[3])
        if not ok or info == nil then return end
        local playing_ok, playing_id = pcall(info.call, info, "get_PlayingId")
        local duration_ok, duration = pcall(info.call, info, "get_Duration")
        if not duration_ok or tonumber(duration) == nil or tonumber(duration) <= 0 then
            duration_ok, duration = pcall(info.call, info, "get_EstimatedDuration")
        end
        if playing_ok and duration_ok and playing_id ~= nil and tonumber(duration) and tonumber(duration) > 0 then
            pending_durations[#pending_durations + 1] = {
                playing_id = tostring(playing_id),
                duration_ms = math.floor(tonumber(duration) + 0.5),
                deadline = os.clock() + 2.0
            }
        end
    end
    local hook_ok = pcall(sdk.hook, method, on_pre, function() end)
    if hook_ok then
        duration_hook_installed = true
        append("HOOK_INSTALLED\tSoundCallbackManager.onDuration(DurationCallbackInfo)")
    else
        append("HOOK_INSTALL_FAILED\tSoundCallbackManager.onDuration")
    end
end

-- Hook Wwise 结束回调并测量实际播放时长；只入队标量，列表更新由帧线程完成。
local function install_end_event_hook()
    if end_event_hook_installed then return end
    local manager_type = type_exists("soundlib.SoundManager")
    if not manager_type then return end
    local method = manager_type:get_method("onEndOfEvent(via.simplewwise.EventCallbackInfo)")
    if not method then
        append("HOOK_OVERLOAD_NOT_FOUND\tSoundManager.onEndOfEvent")
        return
    end
    local function on_pre(args)
        local ok, info = pcall(sdk.to_managed_object, args[3])
        if not ok or info == nil then return end
        local playing_ok, playing_id = pcall(info.call, info, "get_PlayingId")
        if not playing_ok or playing_id == nil then return end
        local playing_key = tostring(playing_id)
        local started_at = playing_started_at[playing_key]
        if started_at and #pending_durations < 128 then
            pending_durations[#pending_durations + 1] = {
                playing_id = playing_key,
                stable_key = playing_stable_keys[playing_key],
                duration_ms = math.max(1, math.floor((os.clock() - started_at) * 1000 + 0.5)),
                deadline = os.clock() + 2.0
            }
        end
        playing_started_at[playing_key] = nil
    end
    local hook_ok = pcall(sdk.hook, method, on_pre, function() end)
    if hook_ok then
        end_event_hook_installed = true
        append("HOOK_INSTALLED\tSoundManager.onEndOfEvent(EventCallbackInfo)")
    else
        append("HOOK_INSTALL_FAILED\tSoundManager.onEndOfEvent")
    end
end

local candidates = {
    "soundlib.SoundManager",
    "app.SoundManagerApp",
    "app.SoundEffectTriggerManager",
    "app.SoundNpcVoiceManager",
    "app.SoundDialogueTriggerManager",
    "app.SoundMusicManager",
    "app.SoundVariousManager",
    "via.sound.SoundComponent",
    "via.sound.SoundTriggerList",
    "via.sound.SoundTriggerElement"
}

append("BEGIN\t" .. VERSION)
for _, name in ipairs(candidates) do
    describe_type(name)
end
install_observe_hook()
install_post_request_info_hook()
install_playing_pair_hook()
install_duration_hook()
install_end_event_hook()
append("END\t" .. VERSION)

-- 按稳定键在与 REFF 近期列表相同的分类存储中查找事件。
-- 网页列表使用会话级聚合，而 recent_events 是 500 条环形队列；收藏旧行必须走同一数据源，
-- 否则用户在页面上看到的事件可能已被环形队列淘汰，导致收藏报 recent_event_not_found。
local function find_recent_event_by_key(stable_key)
    local stores = {browser_player_events, browser_npc_events, browser_otomo_events,
        browser_weapon_events, browser_unknown_events}
    local found = nil
    for _, store in ipairs(stores) do
        local event = EventStore.find_latest(store, stable_key)
        if event and (found == nil or (event.sequence or 0) > (found.sequence or 0)) then
            found = event
        end
    end
    return found
end

-- REFF 服务通过窄接口读取帧线程状态并提交配置事务；网页无法访问 Hook 或运行时对象。
local reff_handle, reff_error = VoiceControllerREFF.register({
    get_status = function()
        local audio = REFAudioClient.get_status(replacement_client)
        return {
            hooksReady = hook_installed and request_hook_installed and playing_pair_hook_installed,
            totalCaptured = total_captured,
            droppedPending = dropped_pending,
            voiceIndexReady = voice_index_ready,
            catalogReady = catalog_ready,
            catalogCount = catalog_count,
            configSchema = replacement_config_schema,
            mode = replacement_mode,
            ruleCount = replacement_rule_count,
            matched = replacement_matched,
            submitted = audio.submitted or 0,
            suppressed = replacement_suppressed,
            failed = audio.failed or 0,
            groupDirectoriesReady = audio.groupDirectoriesReady == true,
            groupFolderCount = group_scan and #group_scan.groups or 0,
            groupRejectedCount = #group_rejects,
            groupConflictCount = #group_conflicts,
            groupUnwritableCount = #GroupStore.unwritable_folders(
                replacement_config and replacement_config.groups),
            testPlaybackRequested = test_playback_requested,
            testPlaybackSubmitted = test_playback_submitted,
            testPlaybackFailed = test_playback_failed
        }
    end,
    get_recent_events = function()
        local result = {}
        local stores = {browser_player_events, browser_npc_events, browser_otomo_events,
            browser_weapon_events, browser_unknown_events}
        for _, store in ipairs(stores) do
            for _, event in ipairs(EventStore.to_array(store)) do
                event.replayable = GameAudioReplay.can_resolve(game_audio_replay, event.stableKey, event)
                result[#result + 1] = event
            end
        end
        table.sort(result, function(left, right) return (left.sequence or 0) < (right.sequence or 0) end)
        return result
    end,
    get_saved_events = function()
        local events = saved_event_store and SavedEventStore.snapshot(saved_event_store) or {}
        for _, event in ipairs(events) do
            event.replayable = GameAudioReplay.can_resolve(game_audio_replay, event.stableKey, event)
            event.durationMs = duration_by_key[event.stableKey] or event.durationMs
        end
        return events
    end,
    get_saved_event = function(stable_key)
        for _, event in ipairs(saved_event_store and SavedEventStore.snapshot(saved_event_store) or {}) do
            if event.stableKey == stable_key then return event end
        end
        return nil
    end,
    get_catalog = function()
        return catalog_snapshot
    end,
    -- 只返回分组文件夹的元数据；规则体本身就在 config.groups 里，不再重复推送。
    get_group_folders = function()
        local result = {}
        local by_folder = {}
        for _, group in ipairs(replacement_config and replacement_config.groups or {}) do
            if type(group) == "table" and type(group.source) == "table" then
                local folder = group.source.folder or group.source.packId
                if type(folder) == "string" and folder ~= "" then by_folder[folder] = true end
            end
        end
        for _, entry in ipairs(group_scan and group_scan.groups or {}) do
            result[#result + 1] = {
                folder = entry.folder,
                name = entry.name,
                version = entry.version,
                author = entry.author,
                description = entry.description,
                audioDirectory = entry.audio_directory,
                hasManifest = entry.has_manifest == true,
                -- 非 ASCII 目录名无法回写 group.json（REFramework 文件 API 只支持 ASCII 路径）。
                writable = entry.writable ~= false,
                registered = by_folder[entry.folder] == true,
                ruleCount = #(type(entry.rules) == "table" and entry.rules or {}),
                -- 空 Lua 表会被编码成 null，UI 侧需按 null 兜底；这里干脆省略空告警。
                warnings = #entry.warnings > 0 and entry.warnings or nil
            }
        end
        return result
    end,
    get_conflicts = function()
        return group_conflicts
    end,
    get_group_rejects = function()
        return group_rejects
    end,
    get_unwritable_folders = function()
        return GroupStore.unwritable_folders(replacement_config and replacement_config.groups)
    end,
    get_config_manager = function()
        return config_manager
    end,
    get_config_manager_error = function()
        return config_manager_error
    end,
    save_event = function(stable_key)
        if not saved_event_store then return false, {saved_event_error or "saved_events_unavailable"} end
        local event = find_recent_event_by_key(stable_key)
            or EventStore.find_latest(recent_events, stable_key)
        if not event then return false, {"recent_event_not_found"} end
        local saved, err = SavedEventStore.add(saved_event_store, event)
        if saved then queue_runtime_message("SAVED_EVENT_ADDED\tkey=" .. tostring(stable_key)) end
        return saved, {err}
    end,
    remove_saved_event = function(stable_key)
        if not saved_event_store then return false, {saved_event_error or "saved_events_unavailable"} end
        local references = config_manager and ConfigManager.find_rule_references(config_manager, stable_key) or {}
        if #references > 0 then return false, {"saved_event_in_use." .. table.concat(references, ",")} end
        local removed, err = SavedEventStore.remove(saved_event_store, stable_key)
        if removed then queue_runtime_message("SAVED_EVENT_REMOVED\tkey=" .. tostring(stable_key)) end
        return removed, {err}
    end,
    play_event = function(stable_key)
        local event = nil
        if saved_event_store then
            event = SavedEventStore.snapshot(saved_event_store)
            for _, item in ipairs(event) do
                if item.stableKey == stable_key then event = item break end
            end
            if type(event) ~= "table" or event.stableKey ~= stable_key then event = nil end
        end
        event = event or find_recent_event_by_key(stable_key) or EventStore.find_latest(recent_events, stable_key)
        local queued, err = GameAudioReplay.enqueue(game_audio_replay, stable_key, event)
        if queued then queue_runtime_message("GAME_AUDIO_PLAY_QUEUED\tkey=" .. tostring(stable_key)) end
        return queued, {err}
    end,
    ensure_group_directory = function(path)
        if type(path) ~= "string" or path == "" then return false, {"group_directory_missing"} end
        local status = REFAudioClient.get_status(replacement_client)
        if not status.groupDirectoriesReady then return false, {"group_directory_backend_unavailable"} end
        local queued = REFAudioClient.enqueue_ensure_group_directory(replacement_client, path)
        return queued, queued and nil or {"audio_queue_full"}
    end,
    save_config = function(manager)
        if manager ~= config_manager then return false, "stale_editor" end
        local saved, err = ConfigManager.save(manager, REPLACEMENT_CONFIG, {
            utf8_read = Utf8FileBridge.read,
            utf8_write = Utf8FileBridge.write
        })
        if saved then
            replacement_config_fingerprint = nil
            next_config_reload = 0
            -- 清单写回后立即重新扫描目录，刷新 hasManifest 与新文件夹状态。
            group_signature = nil
            next_group_scan = 0
            queue_runtime_message("CONFIG_EDITOR_SAVED")
            -- 非 ASCII 目录名的分组无法回写 group.json，日志里逐条说明，避免界面“保存成功”造成误解。
            for _, entry in ipairs(manager.manifest_skipped or {}) do
                queue_runtime_message(string.format(
                    "GROUP_MANIFEST_SKIPPED\tgroup=%s\tfolder=%s\treason=%s",
                    tostring(entry.id), tostring(entry.folder), tostring(entry.code)))
            end
        else
            config_manager_error = err
            queue_runtime_message("CONFIG_EDITOR_SAVE_FAILED\t" .. tostring(err))
        end
        return saved, err
    end,
    test_candidate = function(manager, group_id, rule_id, candidate_index)
        if manager ~= config_manager then return false, {"stale_editor"} end
        local resolved, spec = ConfigManager.get_candidate_playback_spec(
            manager, group_id, rule_id, candidate_index)
        if not resolved then return false, spec end
        if not REFAudioClient.enqueue_load(replacement_client, spec) then
            return false, {"audio_queue_full"}
        end
        test_playback_requested = test_playback_requested + 1
        queue_runtime_message(string.format(
            "TEST_PLAYBACK_QUEUED\tgroup=%s\trule=%s\tcandidate=%d",
            tostring(group_id), tostring(rule_id), candidate_index))
        return true
    end
})
if reff_handle then
    append("REFF_SERVICE_READY\tplugin=voice-controller")
else
    append("REFF_SERVICE_UNAVAILABLE\treason=" .. tostring(reff_error))
end

re.on_frame(function()
    local now = os.clock()
    REFAudioClient.refresh_backend(replacement_client, now)
    reload_replacement_config(now)
    scan_audio_catalog(now)
    scan_groups(now)
    if ReplacementRuntime.requires_preflight(replacement_runtime)
        and now >= next_replacement_preflight
    then
        next_replacement_preflight = now + 1.0
        replacement_preflight_error = nil
        replacement_preflight_ready = ReplacementRuntime.refresh_preflight(
            replacement_runtime,
            function(file)
                local ready, err = REFAudioClient.preflight(replacement_client, file, now)
                if not ready and replacement_preflight_error == nil then
                    replacement_preflight_error = err
                end
                return ready, err
            end)
    else
        if not ReplacementRuntime.requires_preflight(replacement_runtime) then
            replacement_preflight_ready = false
            replacement_preflight_error = nil
        end
    end
    try_build_voice_index()
    scan_scene_containers(now)
    local replay_result = GameAudioReplay.tick(game_audio_replay)
    if replay_result and replay_result.kind == "submitted" then
        if replay_result.request_id then
            local request_key = tostring(replay_result.request_id)
            request_stable_keys[request_key] = replay_result.stable_key
            if request_playing_ids[request_key] then
                playing_stable_keys[request_playing_ids[request_key]] = replay_result.stable_key
                request_playing_ids[request_key] = nil
            end
        end
        if replay_result.playing_id and replay_result.playing_id ~= "0" then
            playing_stable_keys[tostring(replay_result.playing_id)] = replay_result.stable_key
        end
        queue_runtime_message("GAME_AUDIO_PLAY_SUBMITTED\tkey=" .. tostring(replay_result.stable_key))
    elseif replay_result and replay_result.kind == "error" then
        queue_runtime_message("GAME_AUDIO_PLAY_FAILED\tkey=" .. tostring(replay_result.stable_key)
            .. "\treason=" .. tostring(replay_result.reason))
    end
    REFAudioClient.update_spatial(replacement_client, now)
    local audio_result = REFAudioClient.tick(replacement_client, now)
    if audio_result and audio_result.kind == "submitted" then
        if audio_result.source == "test" then
            test_playback_submitted = test_playback_submitted + 1
            queue_runtime_message(string.format("TEST_PLAYBACK_SUBMITTED\tchannel=%s",
                tostring(audio_result.channel_id)))
        else
            queue_runtime_message(string.format("REPLACEMENT_SUBMITTED\tkey=%s\tchannel=%s",
                tostring(audio_result.stable_key), tostring(audio_result.channel_id)))
        end
    elseif audio_result and audio_result.kind == "error" then
        if audio_result.source == "test" then
            test_playback_failed = test_playback_failed + 1
            queue_runtime_message("TEST_PLAYBACK_FAILED\treason=" .. tostring(audio_result.reason))
        else
            queue_runtime_message("REPLACEMENT_FAILED\treason=" .. tostring(audio_result.reason))
        end
    end
    local expired = ReplacementRuntime.expire(replacement_runtime, now * 1000)
    if expired > 0 then replacement_tokens_expired = replacement_tokens_expired + expired end
    expire_pending_stops(now)
    flush_pending()
end)
