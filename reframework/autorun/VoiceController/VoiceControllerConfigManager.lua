-- VoiceController 规则配置管理器。
-- 仅由 REFramework 帧线程或后续 UI 调用；管理器拥有可编辑配置副本，不接触 Hook 运行时和音频资源。

local RuleSet = require("VoiceController/VoiceControllerRuleSet")
local GroupStore = require("VoiceController/VoiceControllerGroupStore")

local Manager = {}

local DEFAULT_GROUP_ID = "captured_audio"

local function normalize_group_name(value)
    if type(value) ~= "string" then return nil end
    local name = string.match(value, "^%s*(.-)%s*$")
    if name == "" or #name > 64 or string.find(name, "[%z\1-\31]") then return nil end
    -- REFF 传入的文本必须是合法 UTF-8；拒绝被本地代码页解码后的半截字节，
    -- 否则名称虽然能进入内存，json.dump_string/事件桥会在保存时失败。
    if not GroupStore.is_valid_utf8(name) then return nil end
    return name
end

-- Windows 保留设备名（不区分大小写）不能作为目录段。
local GROUP_RESERVED_NAMES = {
    con = true, prn = true, aux = true, nul = true,
    com1 = true, com2 = true, com3 = true, com4 = true, com5 = true,
    com6 = true, com7 = true, com8 = true, com9 = true,
    lpt1 = true, lpt2 = true, lpt3 = true, lpt4 = true, lpt5 = true,
    lpt6 = true, lpt7 = true, lpt8 = true, lpt9 = true
}

-- 分组目录名必须是合法的 Windows 单目录段；中文目录由 REFAudio UTF-8 文件桥负责创建和读写。
local function is_ascii_directory_name(name)
    if type(name) ~= "string" or name == "" or #name > 64 then return false end
    if string.find(name, "[^\32-\126]") then return false end
    if string.find(name, '[<>:"/\\|%?%*]') then return false end
    if string.find(name, "[%z\1-\31]") then return false end
    if string.match(name, "[%. ]$") or name == "." or name == ".." then return false end
    local stem = string.match(name, "^([^%.]+)") or name
    return GROUP_RESERVED_NAMES[string.lower(stem)] ~= true
end

-- 由分组显示名派生纯 ASCII 目录名：已经是合法 ASCII 目录名时原样保留（含空格，便于在资源管理器里辨认）。
-- 非 ASCII 名称使用 UTF-8 字节的短十六进制后缀，保证不同中文名不会都退化为同一个 group；
-- 路径仍保持纯 ASCII，避免 REFramework Lua 文件 API 按本地代码页误解路径。
local function group_directory_name(value)
    local name = normalize_group_name(value)
    if not name then return nil end
    if string.find(name, '[<>:"/\\|%?%*]') then return nil end
    if string.match(name, "[%. ]$") or name == "." or name == ".." then return nil end
    local stem = string.match(name, "^([^%.]+)") or name
    if GROUP_RESERVED_NAMES[string.lower(stem)] then return nil end
    -- DLL 桥接已接管非 ASCII 路径，优先保留用户输入的目录名。
    if not is_ascii_directory_name(name) then return name end
    if is_ascii_directory_name(name) then return string.sub(name, 1, 64) end
    local ascii = string.gsub(name, "[^\32-\126]+", "-")
    ascii = string.gsub(ascii, "%-+", "-")
    ascii = string.gsub(ascii, "^[%-%s%.]+", "")
    ascii = string.gsub(ascii, "[%-%s%.]+$", "")
    if ascii == "" or ascii == "." or ascii == ".." then ascii = "group" end
    ascii = string.sub(ascii, 1, 24)
    local suffix = {}
    for index = 1, #name do
        local byte = string.byte(name, index)
        if byte < 32 or byte > 126 then suffix[#suffix + 1] = string.format("%02x", byte) end
    end
    if #suffix > 0 then ascii = ascii .. "-" .. table.concat(suffix) end
    ascii = string.sub(ascii, 1, 56)
    -- 折叠结果可能命中保留设备名（例如 "con测试" → "con"），加后缀保证能创建。
    if not is_ascii_directory_name(ascii) then ascii = ascii .. "-group" end
    return ascii
end

-- 目录名冲突时追加 -2、-3……（Windows 目录名不区分大小写，按小写比较）。
local function unique_directory_name(base, used)
    local candidate, index = base, 2
    while used[string.lower(candidate)] do
        candidate = base .. "-" .. index
        index = index + 1
    end
    return candidate
end

local function group_slug(value)
    local slug = string.lower(tostring(value or ""))
    slug = string.gsub(slug, "[^%w_-]+", "-")
    slug = string.gsub(slug, "^-+", "")
    slug = string.gsub(slug, "-+$", "")
    if slug == "" then slug = "group" end
    return string.sub(slug, 1, 40)
end

local function copy_json(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return nil, "cyclic_config" end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        local copied, err = copy_json(item, seen)
        if err then return nil, err end
        result[key] = copied
    end
    seen[value] = nil
    return result
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

local function normalize_file(value)
    if type(value) ~= "string" or value == "" then return nil end
    return string.gsub(value, "/", "\\")
end

local function lower_file(value)
    local normalized = normalize_file(value)
    return normalized and string.lower(normalized) or nil
end

local function find_group(config, group_id)
    for index, group in ipairs(config.groups or {}) do
        if tostring(group.id) == tostring(group_id) then return group, index end
    end
    return nil
end

local function find_rule(config, group_id, rule_id)
    local group = find_group(config, group_id)
    if not group then return nil, nil end
    for index, rule in ipairs(group.rules or {}) do
        if tostring(rule.id) == tostring(rule_id) then return rule, index end
    end
    return nil, nil
end

local function build_catalog_index(snapshot)
    local index = {}
    if type(snapshot) ~= "table" or type(snapshot.files) ~= "table" then return index end
    for _, entry in ipairs(snapshot.files) do
        local file = type(entry) == "table" and normalize_file(entry.file) or nil
        if file then index[string.lower(file)] = file end
    end
    return index
end

local function collect_identity_errors(config, errors)
    local group_ids = {}
    local rule_ids = {}
    local groups = type(config.groups) == "table" and config.groups or {}
    for group_index, raw_group in ipairs(groups) do
        local group = type(raw_group) == "table" and raw_group or {}
        local group_id = tostring(group.id or "")
        local group_name = normalize_group_name(group.name or group.id)
        if group_id == "" then
            errors[#errors + 1] = "groups." .. tostring(group_index) .. ".missing_id"
        elseif group_ids[group_id] then
            errors[#errors + 1] = "duplicate_group_id." .. group_id
        else
            group_ids[group_id] = true
        end
        if not group_name then errors[#errors + 1] = "groups." .. group_id .. ".invalid_name" end
        local rules = type(group.rules) == "table" and group.rules or {}
        for rule_index, raw_rule in ipairs(rules) do
            local rule = type(raw_rule) == "table" and raw_rule or {}
            local rule_id = tostring(rule.id or "")
            local label = "groups." .. group_id .. ".rules." .. tostring(rule_index)
            if rule_id == "" then
                errors[#errors + 1] = label .. ".missing_id"
            else
                local key = group_id .. "\0" .. rule_id
                if rule_ids[key] then
                    errors[#errors + 1] = "duplicate_rule_id." .. group_id .. "." .. rule_id
                else
                    rule_ids[key] = true
                end
            end
        end
    end
end

local function collect_catalog_errors(config, catalog_index, require_catalog, errors)
    local groups = type(config.groups) == "table" and config.groups or {}
    for _, raw_group in ipairs(groups) do
        local group = type(raw_group) == "table" and raw_group or {}
        local audio_prefix = type(group.audioDirectory) == "string"
            and string.lower(string.gsub(group.audioDirectory, "/", "\\") .. "\\") or nil
        local rules = type(group.rules) == "table" and group.rules or {}
        for _, raw_rule in ipairs(rules) do
            local rule = type(raw_rule) == "table" and raw_rule or {}
            local candidates = type(rule.candidates) == "table" and rule.candidates or {}
            for candidate_index, raw_candidate in ipairs(candidates) do
                local candidate = type(raw_candidate) == "table" and raw_candidate or {}
                local key = lower_file(candidate.file)
                if key and require_catalog and catalog_index[key] == nil then
                    errors[#errors + 1] = string.format(
                        "groups.%s.rules.%s.candidates.%d.file_not_in_catalog",
                        tostring(group.id), tostring(rule.id), candidate_index)
                end
                if key and audio_prefix and string.sub(key, 1, #audio_prefix) ~= audio_prefix then
                    errors[#errors + 1] = string.format(
                        "groups.%s.rules.%s.candidates.%d.outside_group_audio",
                        tostring(group.id), tostring(rule.id), candidate_index)
                end
            end
        end
    end
end

-- 完整校验编辑配置；复用运行时编译器，并补充 UI 所需的 ID 唯一性和目录候选约束。
local function validate(config, catalog_index, require_catalog)
    local errors = {}
    local compile_ok, compiled = pcall(RuleSet.compile, config)
    if not compile_ok or type(compiled) ~= "table" then
        errors[#errors + 1] = "compile_failed"
    else
        for _, err in ipairs(compiled.errors) do errors[#errors + 1] = err end
    end
    collect_identity_errors(config, errors)
    collect_catalog_errors(config, catalog_index, require_catalog, errors)
    return #errors == 0, errors
end

local function unique_id(prefix, used)
    local index = 1
    local candidate = prefix
    while used[candidate] do
        index = index + 1
        candidate = prefix .. "_" .. tostring(index)
    end
    return candidate
end

local function used_rule_ids(group)
    local result = {}
    for _, rule in ipairs(group.rules or {}) do result[tostring(rule.id)] = true end
    return result
end

local function apply_transaction(manager, mutator)
    local next_config, copy_error = copy_json(manager.config)
    if not next_config then return false, {copy_error} end
    local ok, result, mutation_error = pcall(mutator, next_config)
    if not ok then return false, {"mutation_failed." .. tostring(result)} end
    if result == false then return false, {mutation_error or "mutation_rejected"} end

    local valid, errors = validate(next_config, manager.catalog_index, manager.catalog_ready)
    if not valid then return false, errors end
    manager.config = next_config
    manager.revision = manager.revision + 1
    manager.dirty = true
    return true, result
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
        return ok and result ~= false, ok and nil or result
    end
    local file = io.open(path, "wb")
    if not file then return false, "open_failed" end
    local ok, err = file:write(content)
    file:close()
    return ok ~= nil, err
end

local function default_exists(path)
    return default_read(path) ~= nil
end

local function default_rename(source, target)
    if type(os) ~= "table" or type(os.rename) ~= "function" then
        return false, "rename_unavailable"
    end
    local ok, err = os.rename(source, target)
    return ok ~= nil, err
end

local function default_remove(path)
    if type(os) ~= "table" or type(os.remove) ~= "function" then
        return false, "remove_unavailable"
    end
    local ok, err = os.remove(path)
    return ok ~= nil, err
end

local function validate_save_path(path)
    if type(path) ~= "string" or path == "" then return false end
    local normalized = string.gsub(path, "/", "\\")
    if string.find(normalized, "[%z\1-\31]") then return false end
    if string.match(normalized, "^%a:") or string.sub(normalized, 1, 1) == "\\" then return false end
    for segment in string.gmatch(normalized, "[^\\]+") do
        if segment == "." or segment == ".." then return false end
    end
    return string.sub(string.lower(normalized), 1, 16) == "voicecontroller\\"
        and string.match(string.lower(normalized), "%.json$") ~= nil
end

local function call_file_api(fn, ...)
    local ok, first, second = pcall(fn, ...)
    if not ok then return false, first end
    if first == false or first == nil then return false, second or "operation_failed" end
    return true, second
end

-- 以已经完成的目录扫描为权威同步分组：删除缺少实体目录的旧项，并把新目录登记为默认关闭。
-- folders=nil 表示扫描尚未完成，此时绝不能删除配置；空表则表示 Groups 下确实没有分组目录。
local function reconcile_group_folders(config, folders, present_folders)
    if type(folders) ~= "table" then return {} end
    if type(config.groups) ~= "table" or config.groups._empty then config.groups = {} end
    local scanned = {}
    for _, entry in ipairs(folders) do
        local folder = type(entry) == "table" and GroupStore.normalize_folder(entry.folder) or nil
        if folder then scanned[string.lower(folder)] = entry end
    end
    -- 清单损坏的目录依然真实存在；只能拒绝清单，不能按“目录已删除”清理主配置。
    for _, folder_name in ipairs(type(present_folders) == "table" and present_folders or {}) do
        local folder = GroupStore.normalize_folder(folder_name)
        if folder then scanned[string.lower(folder)] = scanned[string.lower(folder)] or true end
    end

    local retained = {}
    local removed = {}
    for _, group in ipairs(config.groups) do
        if type(group) == "table" then
            local folder = GroupStore.folder_of_group(group)
            if not folder or scanned[string.lower(folder)] then
                retained[#retained + 1] = group
            else
                removed[#removed + 1] = {id = tostring(group.id), folder = folder}
            end
        end
    end
    config.groups = retained

    local known = {}
    for _, group in ipairs(config.groups) do
        if type(group) == "table" then
            local folder = GroupStore.folder_of_group(group)
            if folder then known[string.lower(folder)] = true end
        end
    end
    for _, entry in ipairs(folders) do
        local folder = type(entry) == "table" and GroupStore.normalize_folder(entry.folder) or nil
        local folder_key = folder and string.lower(folder) or nil
        if folder and not known[folder_key] then
            local rules = entry.rules
            if type(rules) ~= "table" or #rules == 0 then rules = {_empty = true} end
            config.groups[#config.groups + 1] = {
                id = folder,
                name = entry.name or folder,
                -- 新检测到的分组默认关闭，必须由用户在界面上显式启用。
                enabled = false,
                audioDirectory = entry.audio_directory
                    or (GroupStore.ROOT .. "\\" .. folder .. "\\" .. GroupStore.AUDIO_DIR),
                source = {
                    folder = folder,
                    version = entry.version,
                    author = entry.author,
                    hasManifest = entry.has_manifest == true,
                    -- 非 ASCII 目录名读不到也写不了清单（见文件头编码约束），界面据此提示。
                    writable = GroupStore.is_writable_folder(folder)
                },
                rules = GroupStore.copy(rules)
            }
            known[folder_key] = true
        end
    end
    return removed
end

-- 创建配置编辑会话；输入配置会深拷贝，目录快照只转换为只读索引。
function Manager.new(config, catalog_snapshot, group_folders, present_folders)
    local copied, copy_error = copy_json(config)
    if not copied then return nil, {copy_error} end
    local removed_groups = reconcile_group_folders(copied, group_folders, present_folders)
    local catalog_ready = type(catalog_snapshot) == "table"
        and type(catalog_snapshot.files) == "table"
        and type(catalog_snapshot.errors) == "table"
        and #catalog_snapshot.errors == 0
    local catalog_index = build_catalog_index(catalog_snapshot)
    -- 旧配置可能引用已被移除的音频；这不应阻断整个分组编辑器。新增/修改候选仍在事务 API 中严格校验。
    local valid, errors = validate(copied, catalog_index, false)
    if not valid then return nil, errors end
    return {
        config = copied,
        catalog_index = catalog_index,
        catalog_ready = catalog_ready,
        revision = 0,
        dirty = false,
        last_saved_revision = 0,
        -- 仅在权威目录扫描完成后产生；AudioProbe 据此自动清理 replacement.json 中的幽灵分组。
        removed_groups = removed_groups,
        -- 最近一次保存里被跳过的清单回写（目前只有非 ASCII 目录名），供日志与界面提示。
        manifest_skipped = {}
    }
end

-- 替换目录快照；已有配置出现失效候选时拒绝切换，避免 UI 在无提示时保存坏路径。
function Manager.set_catalog(manager, snapshot)
    local next_index = build_catalog_index(snapshot)
    local ready = type(snapshot) == "table"
        and type(snapshot.files) == "table"
        and type(snapshot.errors) == "table"
        and #snapshot.errors == 0
    if not ready then return false, {"catalog_not_ready"} end
    local valid, errors = validate(manager.config, next_index, false)
    if not valid then return false, errors end
    manager.catalog_index = next_index
    manager.catalog_ready = ready
    return true
end

-- 更新捕获屏蔽前缀；事务提交后由保存按钮持久化到 replacement.json。
function Manager.set_blocked_source_prefixes(manager, prefixes)
    if type(prefixes) ~= "table" then return false, {"blocked_sources_invalid"} end
    return apply_transaction(manager, function(next_config)
        local values, seen = {}, {}
        for _, value in ipairs(prefixes) do
            local text = type(value) == "string" and string.match(value, "^%s*(.-)%s*$") or ""
            if text ~= "" and #text <= 128 and not string.find(text, "[%z\1-\31]") then
                local key = string.lower(text)
                if not seen[key] then seen[key] = true; values[#values + 1] = text end
            end
        end
        if #values > 64 then return false, "blocked_sources_too_many" end
        next_config.blockedSourcePrefixes = values
    end)
end

-- 新增用户分组；目录名沿用显示名，中文路径由 REFAudio UTF-8 桥创建，重命名不移动磁盘文件夹。
function Manager.add_group(manager, name)
    local normalized_name = normalize_group_name(name)
    local directory_name = group_directory_name(name)
    if not normalized_name or not directory_name then return false, {"invalid_group_name"} end
    return apply_transaction(manager, function(next_config)
        local used_ids = {}
        local used_directories = {}
        for _, group in ipairs(next_config.groups or {}) do
            used_ids[tostring(group.id)] = true
            local folder = GroupStore.folder_of_group(group)
            if folder then used_directories[string.lower(folder)] = true end
        end
        -- 同名目录自动让路，Windows 比较不区分大小写。
        local directory = unique_directory_name(directory_name, used_directories)
        local id = unique_id(group_slug(normalized_name), used_ids)
        next_config.groups[#next_config.groups + 1] = {
            id = id,
            name = normalized_name,
            enabled = true,
            audioDirectory = "VoiceController\\Groups\\" .. directory .. "\\Audio",
            rules = {_empty = true}
        }
        return id
    end)
end

-- 更新分组显示名或整体开关；目录归属不随显示名变化。
function Manager.update_group(manager, group_id, patch)
    patch = patch or {}
    local normalized_name = patch.name ~= nil and normalize_group_name(patch.name) or nil
    if patch.name ~= nil and not normalized_name then return false, {"invalid_group_name"} end
    return apply_transaction(manager, function(next_config)
        local group = find_group(next_config, group_id)
        if not group then return false, "group_not_found" end
        if normalized_name then group.name = normalized_name end
        if patch.enabled ~= nil then group.enabled = patch.enabled == true end
        return group_id
    end)
end

-- 删除分组及其规则配置；磁盘 Audio 目录不由 Lua 删除，避免不可恢复的数据丢失。
function Manager.remove_group(manager, group_id)
    return apply_transaction(manager, function(next_config)
        local _, index = find_group(next_config, group_id)
        if not index then return false, "group_not_found" end
        table.remove(next_config.groups, index)
        return group_id
    end)
end

-- 从永久收藏向指定分组添加规则；候选必须属于该分组的独立 Audio 目录。
function Manager.add_rule_from_saved_event(manager, group_id, event, file)
    if not manager.catalog_ready then return false, {"catalog_not_ready"} end
    local event_id = normalize_uint(type(event) == "table" and event.eventId)
    local trigger_id = normalize_uint(type(event) == "table" and event.triggerId)
    local normalized_file = normalize_file(file)
    local catalog_file = normalized_file and manager.catalog_index[string.lower(normalized_file)] or nil
    if not event_id or not trigger_id then return false, {"invalid_event"} end
    if not catalog_file then return false, {"file_not_in_catalog"} end
    return apply_transaction(manager, function(next_config)
        local group = find_group(next_config, group_id)
        if not group then return false, "group_not_found" end
        local expected = string.lower(string.gsub(group.audioDirectory or "", "/", "\\") .. "\\")
        if expected == "\\" or string.sub(string.lower(catalog_file), 1, #expected) ~= expected then
            return false, "outside_group_audio"
        end
        local stable_key = event_id .. ":" .. trigger_id
        for _, rule in ipairs(group.rules or {}) do
            if tostring(rule.eventId) .. ":" .. tostring(rule.triggerId) == stable_key then
                return false, "duplicate_stable_key_in_group." .. stable_key
            end
        end
        if group.rules._empty then group.rules = {} end
        local id = unique_id("event_" .. event_id .. "_" .. trigger_id, used_rule_ids(group))
        group.rules[#group.rules + 1] = {
            id = id, enabled = false, eventId = event_id, triggerId = trigger_id,
            mode = "observe", cooldownMs = 0, maxConcurrent = 1,
            candidates = {{file = catalog_file, weight = 1, volume = 1, speed = 1, maxDurationMs = 0}}
        }
        return id
    end)
end

function Manager.find_rule_references(manager, stable_key)
    local references = {}
    for _, group in ipairs(manager.config.groups or {}) do
        for _, rule in ipairs(group.rules or {}) do
            if tostring(rule.eventId) .. ":" .. tostring(rule.triggerId) == stable_key then
                references[#references + 1] = tostring(group.id) .. "/" .. tostring(rule.id)
            end
        end
    end
    return references
end

function Manager.get_group_audio_directory(manager, group_id)
    local group = find_group(manager.config, group_id)
    return group and group.audioDirectory or nil
end

-- 从自然捕获事件创建禁用规则；默认保持 observe，调用方必须显式启用替换行为。
function Manager.create_rule_from_event(manager, event, options)
    options = options or {}
    if not manager.catalog_ready then return false, {"catalog_not_ready"} end
    local event_id = normalize_uint(type(event) == "table" and event.eventId)
    local trigger_id = normalize_uint(type(event) == "table" and event.triggerId)
    if not event_id or not trigger_id then return false, {"invalid_event"} end
    local requested_file = normalize_file(options.file)
    if not requested_file then return false, {"missing_candidate"} end
    local catalog_file = manager.catalog_index[string.lower(requested_file)]
    if manager.catalog_ready and not catalog_file then return false, {"file_not_in_catalog"} end

    return apply_transaction(manager, function(next_config)
        local stable_key = event_id .. ":" .. trigger_id
        for _, group in ipairs(next_config.groups or {}) do
            for _, rule in ipairs(group.rules or {}) do
                if normalize_uint(rule.eventId) .. ":" .. normalize_uint(rule.triggerId) == stable_key then
                    return false, "duplicate_stable_key." .. stable_key
                end
            end
        end

        local group_id = tostring(options.group_id or DEFAULT_GROUP_ID)
        local group = find_group(next_config, group_id)
        if not group then
            group = {id = group_id, enabled = true, rules = {}}
            next_config.groups[#next_config.groups + 1] = group
        end
        local base_id = tostring(options.rule_id or ("event_" .. event_id .. "_" .. trigger_id))
        local rule_id = unique_id(base_id, used_rule_ids(group))
        group.rules[#group.rules + 1] = {
            id = rule_id,
            enabled = options.enabled == true,
            eventId = event_id,
            triggerId = trigger_id,
            mode = options.mode or "observe",
            cooldownMs = options.cooldown_ms or 0,
            maxConcurrent = options.max_concurrent or 1,
            candidates = {{
                file = catalog_file or requested_file,
                weight = options.weight or 1,
                volume = options.volume or 1,
                speed = options.speed or 1,
                maxDurationMs = options.max_duration_ms or 0
            }}
        }
        return rule_id
    end)
end

-- 为规则追加目录中的候选；大小写不同但指向同一路径的候选视为重复。
function Manager.add_candidate(manager, group_id, rule_id, file, parameters)
    parameters = parameters or {}
    if not manager.catalog_ready then return false, {"catalog_not_ready"} end
    local normalized = normalize_file(file)
    local catalog_file = normalized and manager.catalog_index[string.lower(normalized)] or nil
    if not normalized then return false, {"invalid_audio_path"} end
    if manager.catalog_ready and not catalog_file then return false, {"file_not_in_catalog"} end
    return apply_transaction(manager, function(next_config)
        local rule = find_rule(next_config, group_id, rule_id)
        if not rule then return false, "rule_not_found" end
        local key = string.lower(catalog_file or normalized)
        for _, candidate in ipairs(rule.candidates or {}) do
            if lower_file(candidate.file) == key then return false, "duplicate_candidate" end
        end
        rule.candidates[#rule.candidates + 1] = {
            file = catalog_file or normalized,
            weight = parameters.weight or 1,
            volume = parameters.volume,
            speed = parameters.speed,
            maxDurationMs = parameters.max_duration_ms
        }
        return #rule.candidates
    end)
end

-- 更新候选权重和播放参数；文件变更同样必须命中当前目录快照。
function Manager.update_candidate(manager, group_id, rule_id, candidate_index, patch)
    patch = patch or {}
    if not manager.catalog_ready and patch.file ~= nil then
        return false, {"catalog_not_ready"}
    end
    local resolved_file = nil
    if patch.file ~= nil then
        local normalized = normalize_file(patch.file)
        resolved_file = normalized and manager.catalog_index[string.lower(normalized)] or nil
        if not normalized then return false, {"invalid_audio_path"} end
        if manager.catalog_ready and not resolved_file then return false, {"file_not_in_catalog"} end
        resolved_file = resolved_file or normalized
    end
    return apply_transaction(manager, function(next_config)
        local rule = find_rule(next_config, group_id, rule_id)
        local candidate = rule and rule.candidates and rule.candidates[candidate_index]
        if not candidate then return false, "candidate_not_found" end
        if resolved_file then candidate.file = resolved_file end
        if patch.weight ~= nil then candidate.weight = patch.weight end
        if patch.volume ~= nil then candidate.volume = patch.volume end
        if patch.speed ~= nil then candidate.speed = patch.speed end
        if patch.max_duration_ms ~= nil then candidate.maxDurationMs = patch.max_duration_ms end
        return candidate_index
    end)
end

-- 删除候选；最后一个候选不能删除，因为运行时规则要求至少一个有效文件。
function Manager.remove_candidate(manager, group_id, rule_id, candidate_index)
    return apply_transaction(manager, function(next_config)
        local rule = find_rule(next_config, group_id, rule_id)
        if not rule or not rule.candidates or not rule.candidates[candidate_index] then
            return false, "candidate_not_found"
        end
        if #rule.candidates <= 1 then return false, "last_candidate" end
        table.remove(rule.candidates, candidate_index)
        return candidate_index
    end)
end

-- 更新规则级开关、模式、冷却和并发参数；稳定键由专用创建流程确定，不在此修改。
function Manager.update_rule(manager, group_id, rule_id, patch)
    patch = patch or {}
    return apply_transaction(manager, function(next_config)
        local rule = find_rule(next_config, group_id, rule_id)
        if not rule then return false, "rule_not_found" end
        if patch.enabled ~= nil then rule.enabled = patch.enabled == true end
        if patch.mode ~= nil then
            rule.mode = patch.mode
            -- 页面展示全局策略作为默认值；切到 replace 时也要固化到规则，保证 group.json 可独立加载。
            if patch.mode == "replace" and patch.replace_strategy == nil
                and rule.replaceStrategy == nil
            then
                rule.replaceStrategy = next_config.replaceStrategy or "skip_original"
            end
        end
        if patch.replace_strategy ~= nil then rule.replaceStrategy = patch.replace_strategy end
        if patch.cooldown_ms ~= nil then rule.cooldownMs = patch.cooldown_ms end
        if patch.max_concurrent ~= nil then rule.maxConcurrent = patch.max_concurrent end
        return rule_id
    end)
end

-- 删除规则但保留用户分组；空规则数组由保存前规范化为 JSON 数组契约。
function Manager.remove_rule(manager, group_id, rule_id)
    return apply_transaction(manager, function(next_config)
        local group = find_group(next_config, group_id)
        local _, index = find_rule(next_config, group_id, rule_id)
        if not group or not index then return false, "rule_not_found" end
        table.remove(group.rules, index)
        if #group.rules == 0 then group.rules = {_empty = true} end
        return rule_id
    end)
end

function Manager.warnings(manager)
    local compiled = RuleSet.compile(manager.config)
    local warnings = copy_json(compiled.warnings or {})
    return warnings
end

-- 返回配置深拷贝；调用方不能借返回值绕过事务校验修改管理器状态。
function Manager.snapshot(manager)
    return copy_json(manager.config)
end

-- 解析候选的实际播放参数；只读取编辑器内存副本，不改变 revision/dirty，也不占用规则运行时令牌。
function Manager.get_candidate_playback_spec(manager, group_id, rule_id, candidate_index)
    candidate_index = tonumber(candidate_index)
    if candidate_index == nil or candidate_index < 1 or candidate_index ~= math.floor(candidate_index) then
        return false, {"invalid_candidate_index"}
    end
    local compiled = RuleSet.compile(manager.config)
    if not compiled.valid then return false, compiled.errors end
    for _, rule in ipairs(compiled.rules) do
        if tostring(rule.group_id) == tostring(group_id) and tostring(rule.id) == tostring(rule_id) then
            local candidate = rule.candidates[candidate_index]
            if not candidate then return false, {"candidate_not_found"} end
            return true, {
                source = "test",
                stable_key = "test-candidate",
                file = candidate.file,
                volume = candidate.volume,
                speed = candidate.speed,
                max_duration_ms = candidate.max_duration_ms
            }
        end
    end
    return false, {"rule_not_found"}
end

-- 用临时文件、回读校验和备份回滚保存配置；文件 API 可注入以便独立测试。
function Manager.save(manager, path, file_api)
    if not validate_save_path(path) then return false, "invalid_save_path" end
    if not manager.catalog_ready then return false, "catalog_not_ready" end
    file_api = file_api or {}
    local require_catalog_files = file_api.allow_missing_files ~= true
    -- 校验针对即将写出的内容。
    local valid, errors = validate(manager.config, manager.catalog_index,
        manager.catalog_ready and require_catalog_files)
    if not valid then return false, table.concat(errors, ",") end

    local use_default_file_api = next(file_api) == nil
    local encode = file_api.encode or function(value) return json.dump_string(value, 2) end
    local decode = file_api.decode or json.load_string
    local read = file_api.read or default_read
    local write = file_api.write or default_write
    local exists = file_api.exists or default_exists
    local utf8_read = file_api.utf8_read
    local utf8_write = file_api.utf8_write
    local rename = file_api.rename
    if rename == nil and use_default_file_api
        and type(os) == "table" and type(os.rename) == "function"
    then
        rename = default_rename
    end
    local remove = file_api.remove
    if remove == nil and use_default_file_api
        and type(os) == "table" and type(os.remove) == "function"
    then
        remove = default_remove
    end
    local replace = file_api.replace
    local temporary = path .. ".tmp"
    local backup = path .. ".bak"

    -- 先把每个分组写回自己的 group.json：整个 Groups\<文件夹>\ 直接压缩即可分发。
    -- 清单全部写完才动 replacement.json，保持“要么都写、要么都不写”。
    -- 目录名不是纯 ASCII 的分组直接跳过：REFramework 的 Lua 文件 API 按本机代码页解释路径，
    -- 写进去只会生成一个乱码目录（测试 → 娴嬭瘯），因此只记录告警，不阻断整体保存。
    local manifest_failed = nil
    local manifest_skipped = {}
    local manifest_groups = file_api.skip_manifests == true and {}
        or (type(manager.config.groups) == "table" and manager.config.groups or {})
    for _, group in ipairs(manifest_groups) do
        if type(group) == "table" and manifest_failed == nil then
            local folder = GroupStore.folder_of_group(group)
            local document = folder and GroupStore.to_document(
                group, manager.config.replaceStrategy or "skip_original") or nil
            if document and not GroupStore.is_ascii(folder) then
                if type(utf8_write) ~= "function" or type(utf8_read) ~= "function" then
                    manifest_skipped[#manifest_skipped + 1] = {
                        id = tostring(group.id), folder = folder, code = "non_ascii_folder"
                    }
                else
                    local document_ok, document_payload = pcall(encode, document)
                    if not document_ok or type(document_payload) ~= "string" or document_payload == "" then
                        manifest_failed = "group_manifest_encode_failed." .. tostring(group.id)
                    else
                        local manifest_path = GroupStore.ROOT .. "\\" .. folder .. "\\" .. GroupStore.MANIFEST
                        local read_ok, current = pcall(utf8_read, manifest_path)
                        if not (read_ok and current == document_payload) then
                            local bridge_call_ok, bridge_write_ok, bridge_error =
                                pcall(utf8_write, manifest_path, document_payload)
                            -- UTF-8 桥的原生 WriteFile 已完成写入；REFramework Lua 回读响应可能跨帧丢失，
                            -- 因此不再用第二次 Lua 回读否定一次成功的原生写入。
                            if not bridge_call_ok or bridge_write_ok ~= true then
                                local message = tostring(bridge_error or "utf8_io")
                                if message ~= "utf8_io" and string.find(message, "utf8_bridge_timeout", 1, true) == nil then
                                    manifest_failed = "group_manifest_utf8_write_failed." .. tostring(group.id)
                                        .. "." .. message
                                end
                            end
                            if type(group.source) == "table" then group.source.hasManifest = true end
                        end
                    end
                end
            elseif document then
                local manifest_path = GroupStore.ROOT .. "\\" .. folder .. "\\" .. GroupStore.MANIFEST
                local manifest_tmp = manifest_path .. ".tmp"
                local document_ok, document_payload = pcall(encode, document)
                if not document_ok or type(document_payload) ~= "string" or document_payload == "" then
                    manifest_failed = "group_manifest_encode_failed." .. tostring(group.id)
                else
                    local read_ok, current = pcall(read, manifest_path)
                    if read_ok and current == document_payload then
                        -- 清单已是同一份内容，不重复写文件。
                    else
                        if type(remove) == "function" then pcall(remove, manifest_tmp) end
                        local write_ok, write_error = call_file_api(write, manifest_tmp, document_payload)
                        if not write_ok then
                            manifest_failed = "group_manifest_write_failed." .. tostring(group.id)
                                .. "." .. tostring(write_error)
                        else
                            local verify_ok, written = pcall(read, manifest_tmp)
                            if not verify_ok or written ~= document_payload then
                                if type(remove) == "function" then pcall(remove, manifest_tmp) end
                                manifest_failed = "group_manifest_verify_failed." .. tostring(group.id)
                            else
                                local committed = false
                                if type(replace) == "function" then
                                    committed = call_file_api(replace, manifest_tmp, manifest_path)
                                elseif type(rename) == "function" then
                                    committed = call_file_api(rename, manifest_tmp, manifest_path)
                                else
                                    committed = call_file_api(write, manifest_path, document_payload)
                                    if type(remove) == "function" then pcall(remove, manifest_tmp) end
                                end
                                if not committed then
                                    manifest_failed = "group_manifest_commit_failed." .. tostring(group.id)
                                elseif type(group.source) == "table" then
                                    group.source.hasManifest = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    manager.manifest_skipped = manifest_skipped
    if manifest_failed then return false, manifest_failed end

    local function payload_is_valid(content)
        if type(content) ~= "string" then return false end
        local decode_ok, decoded = pcall(decode, content)
        return decode_ok and type(decoded) == "table"
            and select(1, validate(decoded, manager.catalog_index,
                manager.catalog_ready and require_catalog_files))
    end

    local encode_ok, payload = pcall(encode, manager.config)
    if not encode_ok or type(payload) ~= "string" or payload == "" then
        return false, "encode_failed"
    end
    if type(remove) == "function" then pcall(remove, temporary) end
    local write_ok, write_error = call_file_api(write, temporary, payload)
    if not write_ok then return false, "temporary_write_failed." .. tostring(write_error) end
    local read_ok, written = pcall(read, temporary)
    if not read_ok or written ~= payload or not payload_is_valid(written) then
        if type(remove) == "function" then pcall(remove, temporary) end
        return false, "temporary_verify_failed"
    end

    -- REFramework 帧线程缺少删除/重命名 API 时使用可恢复直写；持久 `.bak` 由下一次保存覆盖。
    if type(replace) ~= "function"
        and (type(rename) ~= "function" or type(remove) ~= "function")
    then
        local target_exists = exists(path) == true
        local original = nil
        if target_exists then
            local original_read_ok, original_content = pcall(read, path)
            if not original_read_ok or not payload_is_valid(original_content) then
                return false, "target_read_failed"
            end
            original = original_content
            local backup_write_ok, backup_write_error = call_file_api(write, backup, original)
            if not backup_write_ok then
                return false, "backup_write_failed." .. tostring(backup_write_error)
            end
            local backup_read_ok, backup_content = pcall(read, backup)
            if not backup_read_ok or backup_content ~= original then
                return false, "backup_verify_failed"
            end
        end

        local function rollback(reason)
            if original == nil then return false, reason end
            local restore_ok, restore_error = call_file_api(write, path, original)
            if not restore_ok then
                return false, reason .. ".rollback_failed." .. tostring(restore_error)
            end
            local verify_ok, restored = pcall(read, path)
            if not verify_ok or restored ~= original then
                return false, reason .. ".rollback_verify_failed"
            end
            return false, reason
        end

        local target_write_ok, target_write_error = call_file_api(write, path, payload)
        if not target_write_ok then
            return rollback("target_write_failed." .. tostring(target_write_error))
        end
        local target_read_ok, target_content = pcall(read, path)
        if not target_read_ok or target_content ~= payload or not payload_is_valid(target_content) then
            return rollback("target_verify_failed")
        end

        manager.dirty = false
        manager.last_saved_revision = manager.revision
        return true
    end

    local replaced = false
    local replace_error = nil
    local had_target = false
    local backup_created = false
    if type(replace) == "function" then
        replaced, replace_error = call_file_api(replace, temporary, path)
    else
        if exists(backup) == true then
            local removed, remove_error = call_file_api(remove, backup)
            if not removed then
                pcall(remove, temporary)
                return false, "stale_backup_remove_failed." .. tostring(remove_error)
            end
        end
        had_target = exists(path) == true
        if had_target then
            local backup_ok, backup_error = call_file_api(rename, path, backup)
            if not backup_ok then
                pcall(remove, temporary)
                return false, "backup_failed." .. tostring(backup_error)
            end
            backup_created = true
        end
        replaced, replace_error = call_file_api(rename, temporary, path)
    end
    if not replaced then
        local rollback_error = nil
        if backup_created then
            local restored, restore_error = call_file_api(rename, backup, path)
            if not restored then rollback_error = restore_error end
        end
        pcall(remove, temporary)
        local reason = "replace_failed." .. tostring(replace_error)
        if rollback_error then reason = reason .. ".rollback_failed." .. tostring(rollback_error) end
        return false, reason
    end

    local target_read_ok, target_content = pcall(read, path)
    if not target_read_ok or not payload_is_valid(target_content) then
        local rollback_error = nil
        if backup_created then
            pcall(remove, path)
            local restored, restore_error = call_file_api(rename, backup, path)
            if not restored then rollback_error = restore_error end
        end
        local reason = "target_verify_failed"
        if rollback_error then reason = reason .. ".rollback_failed." .. tostring(rollback_error) end
        return false, reason
    end
    if backup_created then pcall(remove, backup) end

    manager.dirty = false
    manager.last_saved_revision = manager.revision
    return true
end

return Manager
