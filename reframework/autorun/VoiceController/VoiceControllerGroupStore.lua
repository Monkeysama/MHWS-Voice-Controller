-- VoiceController 分组文件夹扫描与清单。
-- 仅由 REFramework 帧线程调用；模块不持有文件句柄，目录枚举与读写由调用方注入。
-- 模型：Groups\<文件夹>\ = 一个分组 = 一个可分发单元。
--   - 分组 id 就是文件夹名（不再有 slug 或独立的“包”概念）。
--   - 规则放在该文件夹的 group.json 里，压缩整个文件夹即可分发。
--   - 新检测到的文件夹自动登记为分组，且默认关闭（启用状态保存在 replacement.json）。
--   - 没有清单的文件夹也会成为分组（空规则），因此旧的孤儿目录会直接出现在界面上。
-- 编码约束（重要）：REFramework 的 Lua 文件 API（fs.* / io.* / json.*_file）把路径字符串按
-- CP_ACP（本机代码页）转成宽字符路径，含中文的目录名会被写到另一个名字上（测试 → 娴嬭瘯），
-- 且读到的是同一批错误名字（自洽但和资源管理器里看到的不是同一个目录）。
-- 因此：**插件只写入纯 ASCII 文件夹名**；非 ASCII 文件夹仍可被发现/播放（原生清单是 UTF-8），
-- 但不能回写 group.json，界面与日志会明确提示。

local GroupStore = {}

local RuleSet = require("VoiceController/VoiceControllerRuleSet")
local ActionContext = require("VoiceController/VoiceControllerActionContext")

GroupStore.ROOT = "VoiceController\\Groups"
GroupStore.AUDIO_DIR = "Audio"
GroupStore.MANIFEST = "group.json"
GroupStore.SCHEMA_VERSION = 1
-- fs.glob 实际是 std::regex_match（整串匹配）：反斜杠写成 \\、通配是 .*，而且只返回文件路径。
-- 分隔符同时接受 \ 与 /，避免宿主改变路径风格后直接失配。
GroupStore.SCAN_PATTERN = "VoiceController[\\\\/]Groups[\\\\/].*"

-- 校验 UTF-8：glob 返回的是本机代码页字节，非 ASCII 名字可能是乱码，绝不能进入 JSON 或界面。
local function is_valid_utf8(value)
    if type(value) ~= "string" then return false end
    local index, length = 1, #value
    while index <= length do
        local byte = string.byte(value, index)
        local size, minimum, maximum
        if byte < 0x80 then
            size, minimum, maximum = 1, 0x00, 0x7F
        elseif byte >= 0xC2 and byte <= 0xDF then
            size, minimum, maximum = 2, 0x80, 0xBF
        elseif byte == 0xE0 then
            size, minimum, maximum = 3, 0xA0, 0xBF
        elseif byte >= 0xE1 and byte <= 0xEC then
            size, minimum, maximum = 3, 0x80, 0xBF
        elseif byte == 0xED then
            size, minimum, maximum = 3, 0x80, 0x9F
        elseif byte >= 0xEE and byte <= 0xEF then
            size, minimum, maximum = 3, 0x80, 0xBF
        elseif byte == 0xF0 then
            size, minimum, maximum = 4, 0x90, 0xBF
        elseif byte >= 0xF1 and byte <= 0xF3 then
            size, minimum, maximum = 4, 0x80, 0xBF
        elseif byte == 0xF4 then
            size, minimum, maximum = 4, 0x80, 0x8F
        else
            return false
        end
        if index + size - 1 > length then return false end
        local second = size > 1 and string.byte(value, index + 1) or nil
        if second and (second < minimum or second > maximum) then return false end
        for offset = 2, size - 1 do
            local continuation = string.byte(value, index + offset)
            if continuation < 0x80 or continuation > 0xBF then return false end
        end
        index = index + size
    end
    return true
end

-- 纯 ASCII（可打印区间）：只有这类路径能被 REFramework 的文件 API 正确定位。
local function is_ascii(value)
    return type(value) == "string" and value ~= ""
        and string.find(value, "[^\32-\126]") == nil
end

GroupStore.is_valid_utf8 = is_valid_utf8
GroupStore.is_ascii = is_ascii

-- 文件夹名必须是可以直接创建的 Windows 目录段；允许中文与空格（读取侧），写入侧另外限制。
local function normalize_folder(value)
    if type(value) ~= "string" then return nil, "invalid_folder" end
    local name = string.match(value, "^%s*(.-)%s*$")
    if name == "" or #name > 64 then return nil, "invalid_folder" end
    if not is_valid_utf8(name) then return nil, "invalid_folder" end
    if string.find(name, "[%z\1-\31]") then return nil, "invalid_folder" end
    if string.find(name, '[<>:"/\\|%?%*]') then return nil, "invalid_folder" end
    if string.match(name, "[%. ]$") or name == "." or name == ".." then
        return nil, "invalid_folder"
    end
    return name
end

GroupStore.normalize_folder = normalize_folder

-- 能否把清单写进该文件夹的路径；非 ASCII 目录名一律视为不可写（见文件头编码约束）。
function GroupStore.is_writable_folder(folder)
    return normalize_folder(folder) ~= nil
end

-- 列出无法回写清单的分组，供界面与日志提示。
function GroupStore.unwritable_folders(groups)
    local result = {}
    for _, group in ipairs(type(groups) == "table" and groups or {}) do
        if type(group) == "table" then
            local folder = GroupStore.folder_of_group(group)
            if folder and not GroupStore.is_writable_folder(folder) then
                result[#result + 1] = {id = tostring(group.id), folder = folder}
            end
        end
    end
    return result
end

-- 从分组的 audioDirectory 推出磁盘目录段；非本模型分组返回 nil。
function GroupStore.folder_of_group(group)
    if type(group) ~= "table" or type(group.audioDirectory) ~= "string" then return nil end
    local directory = string.gsub(group.audioDirectory, "/", "\\")
    local lowered = string.lower(directory)
    local prefix = string.lower(GroupStore.ROOT) .. "\\"
    if string.sub(lowered, 1, #prefix) ~= prefix then return nil end
    local tail = string.sub(directory, #prefix + 1)
    local folder = string.match(tail, "^([^\\]+)\\Audio$")
    if not folder then return nil end
    return normalize_folder(folder) and folder or nil
end

-- 深拷贝纯数据表；清单与本地配置之间必须隔离引用。
function GroupStore.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = GroupStore.copy(item) end
    return result
end

-- 生成与键序无关的确定性字符串；用于比较分组是否被本地修改过。
function GroupStore.canonical(value)
    local function encode(item, seen)
        local kind = type(item)
        if kind ~= "table" then return kind .. ":" .. tostring(item) end
        if seen[item] then return "cycle" end
        seen[item] = true
        local keys = {}
        for key in pairs(item) do keys[#keys + 1] = key end
        table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = encode(key, seen) .. "=" .. encode(item[key], seen)
        end
        seen[item] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return encode(value, {})
end

-- 音频候选只允许指向本分组自己的 Audio 目录；接受 "Audio/x.wav"、"x.wav" 或完整路径。
local function resolve_audio_path(folder, value)
    if type(value) ~= "string" or value == "" then return nil, "invalid_audio_path" end
    if string.find(value, "[%z\1-\31]") then return nil, "invalid_audio_path" end
    local path = string.gsub(value, "/", "\\")
    path = string.gsub(path, "^%.[\\/]", "")
    if string.match(path, "^%a:") or string.sub(path, 1, 1) == "\\" then
        return nil, "invalid_audio_path"
    end
    for segment in string.gmatch(path, "[^\\]+") do
        if segment == "." or segment == ".." then return nil, "invalid_audio_path" end
    end
    local audio_root = GroupStore.ROOT .. "\\" .. folder .. "\\" .. GroupStore.AUDIO_DIR .. "\\"
    local prefix = string.lower(audio_root)
    local lowered = string.lower(path)
    local relative = nil
    if string.sub(lowered, 1, #prefix) == prefix then
        relative = string.sub(path, #prefix + 1)
    elseif string.sub(lowered, 1, 6) == "audio\\" then
        relative = string.sub(path, 7)
    elseif string.find(path, "\\", 1, true) == nil then
        relative = path
    end
    if not relative or relative == "" then return nil, "audio_outside_group" end
    if string.find(relative, "\\", 1, true) then return nil, "audio_outside_group" end
    local extension = string.match(string.lower(relative), "%.([^%.\\]+)$")
    if extension ~= "mp3" and extension ~= "ogg" and extension ~= "wav" then
        return nil, "unsupported_extension"
    end
    return audio_root .. relative, relative
end

GroupStore.resolve_audio_path = resolve_audio_path

-- 把绝对候选路径还原成清单里的相对形式，保证文件夹可被整体搬移。
local function relative_audio_path(folder, value)
    local full, relative = resolve_audio_path(folder, value)
    if not full then return nil end
    return GroupStore.AUDIO_DIR .. "\\" .. relative
end

local function normalize_rule(folder, raw_rule, index, errors)
    local label = string.format("rules.%d", index)
    if type(raw_rule) ~= "table" then
        errors[#errors + 1] = label .. ".invalid_rule"
        return nil
    end
    local rule_id = raw_rule.id
    if type(rule_id) ~= "string" or rule_id == "" or #rule_id > 64 then
        errors[#errors + 1] = label .. ".invalid_rule_id"
        return nil
    end
    if string.match(rule_id, "^[%w_%-%.]+$") == nil then
        errors[#errors + 1] = label .. ".invalid_rule_id"
        return nil
    end
    local action = raw_rule.action ~= nil and ActionContext.normalize(raw_rule.action) or nil
    if raw_rule.action ~= nil and action == nil then
        errors[#errors + 1] = label .. ".invalid_action"
        return nil
    end
    local candidates = raw_rule.candidates
    if type(candidates) ~= "table" or #candidates == 0 then
        errors[#errors + 1] = label .. ".missing_candidates"
        return nil
    end
    local resolved = {}
    for candidate_index, candidate in ipairs(candidates) do
        candidate = type(candidate) == "table" and candidate or {}
        local file, relative = resolve_audio_path(folder, candidate.file)
        if candidate.action ~= nil and ActionContext.normalize(candidate.action) == nil then
            errors[#errors + 1] = string.format("%s.candidates.%d.invalid_action",
                label, candidate_index)
        end
        if not file then
            errors[#errors + 1] = string.format("%s.candidates.%d.audio_outside_group",
                label, candidate_index)
        else
            resolved[#resolved + 1] = {
                file = file,
                relative = relative,
                action = candidate.action and ActionContext.normalize(candidate.action) or action,
                weight = candidate.weight,
                volume = candidate.volume,
                speed = candidate.speed,
                maxDurationMs = candidate.maxDurationMs
            }
        end
    end
    if #resolved == 0 then return nil end
    return {
        id = rule_id,
        enabled = raw_rule.enabled ~= false,
        eventId = raw_rule.eventId,
        triggerId = raw_rule.triggerId,
        mode = raw_rule.mode,
        replaceStrategy = raw_rule.replaceStrategy,
        cooldownMs = raw_rule.cooldownMs,
        maxConcurrent = raw_rule.maxConcurrent,
        candidates = resolved
    }
end

-- 解析并校验 group.json；规则里的音频路径重写为 VoiceController\Groups\<folder>\Audio\...
function GroupStore.parse_manifest(folder, raw, catalog_index)
    local ok_folder = normalize_folder(folder)
    if not ok_folder then return nil, {"invalid_folder"} end
    if type(raw) ~= "table" then return nil, {"group_manifest_invalid"} end
    if tonumber(raw.schemaVersion) ~= GroupStore.SCHEMA_VERSION then
        return nil, {"unsupported_group_schema"}
    end
    local name = raw.name
    if name ~= nil and (type(name) ~= "string" or string.match(name, "^%s*$")
        or #name > 64 or not is_valid_utf8(name)) then
        return nil, {"invalid_group_name"}
    end

    local errors = {}
    local warnings = {}
    local rules = {}
    local seen_rule_ids = {}
    for index, raw_rule in ipairs(type(raw.rules) == "table" and raw.rules or {}) do
        local rule = normalize_rule(folder, raw_rule, index, errors)
        if rule then
            if seen_rule_ids[rule.id] then
                errors[#errors + 1] = "duplicate_rule_id." .. rule.id
            else
                seen_rule_ids[rule.id] = true
                rules[#rules + 1] = rule
            end
        end
    end
    if #errors > 0 then return nil, errors end

    local audio_directory = GroupStore.ROOT .. "\\" .. folder .. "\\" .. GroupStore.AUDIO_DIR
    -- 分组必须能独立编译：不得依赖本机全局设置（replace 必须自带 replaceStrategy）。
    local probe_ok, probe = pcall(RuleSet.compile, {
        schemaVersion = 2,
        enabled = true,
        mode = "observe",
        groups = {{
            id = folder,
            name = tostring(name or folder),
            enabled = true,
            audioDirectory = audio_directory,
            rules = rules
        }}
    })
    if not probe_ok or type(probe) ~= "table" or not probe.valid then
        return nil, probe_ok and probe.errors or {"group_compile_failed"}
    end

    if type(catalog_index) == "table" then
        for _, rule in ipairs(rules) do
            for _, candidate in ipairs(rule.candidates) do
                if catalog_index[string.lower(candidate.file)] == nil then
                    warnings[#warnings + 1] = "audio_missing." .. candidate.relative
                end
            end
        end
    end

    return {
        folder = folder,
        name = name or folder,
        version = type(raw.version) == "string" and raw.version or nil,
        author = type(raw.author) == "string" and raw.author or nil,
        description = type(raw.description) == "string" and raw.description or nil,
        audio_directory = audio_directory,
        rules = rules,
        warnings = warnings,
        -- 只用于比较“文件夹里的清单是否与本地配置一致”。
        body_key = GroupStore.canonical({
            name = name or folder,
            rules = rules
        })
    }, nil
end

-- 生成可分发清单文档：候选写回相对路径，整个文件夹可以随意搬移与压缩。
function GroupStore.to_document(group, default_replace_strategy)
    if type(group) ~= "table" then return nil end
    local folder = GroupStore.folder_of_group(group)
    if not folder then return nil end
    local rules = {}
    for _, rule in ipairs(type(group.rules) == "table" and group.rules or {}) do
        local candidates = {}
        for _, candidate in ipairs(type(rule.candidates) == "table" and rule.candidates or {}) do
            local relative = type(candidate.file) == "string"
                and relative_audio_path(folder, candidate.file) or nil
            if relative then
                candidates[#candidates + 1] = {
                    file = relative,
                    action = candidate.action and ActionContext.normalize(candidate.action)
                        or (rule.action and ActionContext.normalize(rule.action)),
                    weight = candidate.weight,
                    volume = candidate.volume,
                    speed = candidate.speed,
                    maxDurationMs = candidate.maxDurationMs
                }
            end
        end
        if #candidates > 0 then
            rules[#rules + 1] = {
                id = tostring(rule.id),
                enabled = rule.enabled ~= false,
                eventId = rule.eventId,
                triggerId = rule.triggerId,
                mode = rule.mode,
                replaceStrategy = rule.replaceStrategy
                    or (rule.mode == "replace" and default_replace_strategy or nil),
                cooldownMs = rule.cooldownMs,
                maxConcurrent = rule.maxConcurrent,
                candidates = candidates
            }
        end
    end
    return {
        schemaVersion = GroupStore.SCHEMA_VERSION,
        name = group.name or folder,
        version = group.source and group.source.version or nil,
        author = group.source and group.source.author or nil,
        description = group.description,
        rules = rules,
        -- 内部比较指纹不属于分发格式，不能写进 group.json。
    }
end

-- 收集 Groups 下的文件夹名：glob 与目录快照并集。
-- glob 走本机代码页，非 ASCII 结果无法与真实目录名对应，因此来自 glob 的名字必须是纯 ASCII，
-- 否则只记一条拒绝记录（不把乱码字节写进 JSON 或界面）；非 ASCII 文件夹靠原生 UTF-8 清单发现。
function GroupStore.collect_folders(glob_fn, catalog_files, pattern)
    local folders = {}
    local rejects = {}
    local rejected_codes = {}
    local function reject(code)
        if not rejected_codes[code] then
            rejected_codes[code] = true
            rejects[#rejects + 1] = {id = "非 ASCII 目录名", code = code}
        end
    end
    local function consider(value, from_glob)
        if type(value) ~= "string" then return end
        local path = string.gsub(value, "/", "\\")
        local folder = string.match(path, "\\[Gg]roups\\([^\\]+)")
            or string.match(path, "^[Gg]roups\\([^\\]+)")
        if not folder then return end
        local ok = normalize_folder(folder)
        if not ok then
            return
        end
        folders[ok] = true
    end
    if type(glob_fn) == "function" then
        local ok, paths = pcall(glob_fn, pattern or GroupStore.SCAN_PATTERN)
        if ok and type(paths) == "table" then
            for _, path in ipairs(paths) do consider(path, true) end
        end
    end
    if type(catalog_files) == "table" then
        for _, entry in ipairs(catalog_files) do
            if type(entry) == "table" then consider(entry.relativePath, false) end
        end
    end
    local result = {}
    for folder in pairs(folders) do result[#result + 1] = folder end
    table.sort(result)
    return result, rejects
end

-- 扫描全部分组文件夹；没有清单的文件夹也会返回空规则分组。
function GroupStore.scan(deps)
    deps = deps or {}
    local entries = {}
    local folders, rejects = GroupStore.collect_folders(
        deps.glob, deps.catalog_files, deps.pattern)
    for _, folder in ipairs(folders) do
        local manifest_path = GroupStore.ROOT .. "\\" .. folder .. "\\" .. GroupStore.MANIFEST
        -- 非 ASCII 目录名读不到清单（路径会被本机代码页改写），按“无清单”处理并标记不可写。
        local readable = GroupStore.is_writable_folder(folder)
        local content = readable and deps.read and deps.read(manifest_path) or nil
        if not readable and type(deps.utf8_read) == "function" then
            content = deps.utf8_read(manifest_path)
        end
        local writable = readable
        if content == nil or content == false or tostring(content) == "" then
            entries[#entries + 1] = {
                folder = folder,
                name = folder,
                audio_directory = GroupStore.ROOT .. "\\" .. folder .. "\\" .. GroupStore.AUDIO_DIR,
                rules = {},
                warnings = {},
                has_manifest = false,
                writable = writable
            }
        else
            local decode_ok, decoded = pcall(deps.decode or json.load_string, content)
            if not decode_ok or type(decoded) ~= "table" then
                rejects[#rejects + 1] = {id = folder, code = "group_manifest_invalid"}
            else
                local body, errors = GroupStore.parse_manifest(folder, decoded, deps.catalog_index)
                if body then
                    body.has_manifest = true
                    body.writable = writable
                    entries[#entries + 1] = body
                else
                    rejects[#rejects + 1] = {
                        id = folder,
                        code = table.concat(errors or {"group_invalid"}, ",")
                    }
                end
            end
        end
    end
    return {groups = entries, rejects = rejects, scanned = #folders}
end

-- 按运行时语义计算稳定键占用：组按顺序、规则按顺序，第一个“已启用”的规则生效。
function GroupStore.collect_conflicts(groups)
    local by_key = {}
    local order = {}
    for _, group in ipairs(groups) do
        local group_enabled = group.enabled ~= false
        local group_id = tostring(group.id)
        for _, rule in ipairs(group.rules or {}) do
            local stable_key = tostring(rule.eventId) .. ":" .. tostring(rule.triggerId)
            local keys = {}
            for _, candidate in ipairs(rule.candidates or {}) do
                keys[ActionContext.rule_key(stable_key, candidate.action or rule.action)] = true
            end
            if next(keys) == nil then keys[ActionContext.rule_key(stable_key, rule.action)] = true end
            for key in pairs(keys) do
                if by_key[key] == nil then
                    by_key[key] = {}
                    order[#order + 1] = key
                end
                by_key[key][#by_key[key] + 1] = {
                    group_id = group_id,
                    group_name = tostring(group.name or group_id),
                    rule_id = tostring(rule.id),
                    mode = tostring(rule.mode or "observe"),
                    enabled = rule.enabled ~= false and group_enabled
                }
            end
        end
    end
    local conflicts = {}
    for _, key in ipairs(order) do
        local entries = by_key[key]
        if #entries > 1 then
            local winner = nil
            local losers = {}
            for _, entry in ipairs(entries) do
                if winner == nil and entry.enabled then
                    winner = entry
                else
                    losers[#losers + 1] = entry
                end
            end
            conflicts[#conflicts + 1] = {
                stableKey = string.match(key, "^([^@]+)") or key,
                actionKey = string.match(key, "@(.+)$"),
                matchKey = key,
                winner = winner,
                losers = losers
            }
        end
    end
    return conflicts
end

-- 合成有效配置：本地分组在前，从文件夹新检测到的分组按文件夹名排序在后并默认关闭。
function GroupStore.compose(local_config, scan)
    local config = type(local_config) == "table" and local_config or {}
    local groups = {}
    local origin = {}
    local scanned_folders = {}
    if type(scan) == "table" then
        for _, entry in ipairs(scan.groups or {}) do
            if type(entry.folder) == "string" then
                scanned_folders[string.lower(entry.folder)] = true
            end
        end
    end
    for _, group in ipairs(type(config.groups) == "table" and config.groups or {}) do
        if type(group) == "table" then
            local copy = GroupStore.copy(group)
            local folder = GroupStore.folder_of_group(copy)
            -- 分组目录被用户直接删除后，不再把 replacement.json 中的旧条目显示成幽灵分组。
            if not folder or type(scan) ~= "table" or scanned_folders[string.lower(folder)] then
                groups[#groups + 1] = copy
                origin[tostring(copy.id)] = folder
                    and {origin = "folder", folder = folder}
                    or {origin = "local"}
            end
        end
    end

    local known = {}
    for _, group in ipairs(groups) do
        local folder = GroupStore.folder_of_group(group)
        if folder then known[string.lower(folder)] = true end
    end

    local imported = {}
    for _, entry in ipairs(type(scan) == "table" and scan.groups or {}) do
        local folder_key = type(entry.folder) == "string" and string.lower(entry.folder) or nil
        if folder_key and not known[folder_key] then
            local rules = entry.rules
            if type(rules) ~= "table" or #rules == 0 then rules = {_empty = true} end
            groups[#groups + 1] = {
                id = entry.folder,
                name = entry.name,
                -- 新检测到的分组默认关闭，必须由用户在界面上显式启用。
                enabled = false,
                audioDirectory = entry.audio_directory,
                source = {
                    folder = entry.folder,
                    version = entry.version,
                    author = entry.author,
                    hasManifest = entry.has_manifest == true,
                    -- 非 ASCII 目录名无法回写清单，界面据此提示（仍可播放与管理规则）。
                    writable = GroupStore.is_writable_folder(entry.folder)
                },
                rules = rules
            }
            origin[entry.folder] = {origin = "folder", folder = entry.folder, imported = true}
            imported[#imported + 1] = entry.folder
            known[folder_key] = true
        end
    end

    local effective = {}
    for key, value in pairs(config) do effective[key] = value end
    effective.groups = groups

    return effective, {
        origin = origin,
        imported = imported,
        unwritable = GroupStore.unwritable_folders(groups),
        conflicts = GroupStore.collect_conflicts(groups)
    }
end

return GroupStore
