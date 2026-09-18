-- VoiceController 外部音频目录扫描器。
-- 仅由帧线程调用；模块不持有文件句柄，目录枚举由调用方注入，Hook 线程不得使用本模块。

local Catalog = {}

Catalog.DEFAULT_PATTERNS = {
    [[VoiceController\\.*]]
}

local SUPPORTED_EXTENSIONS = {
    mp3 = true,
    ogg = true,
    wav = true
}

local ROOT_PREFIXES = {
    "voicecontroller\\",
    "data\\voicecontroller\\",
    "reframework\\data\\voicecontroller\\"
}

local function is_valid_utf8(value)
    if type(value) ~= "string" then return false end
    local ok, length = pcall(utf8.len, value)
    return ok and length ~= nil
end

local function add_error(errors, pattern, code, detail)
    errors[#errors + 1] = {
        pattern = pattern,
        code = code,
        detail = detail and tostring(detail) or nil
    }
end

-- 将 fs.glob 返回值规范化为相对于 reframework/data 的规则路径；拒绝越界和非音频文件。
local function normalize_path(value)
    if type(value) ~= "string" or value == "" then return nil, "invalid_path" end
    if not is_valid_utf8(value) then return nil, "invalid_encoding" end
    if string.find(value, "[%z\1-\31]") then return nil, "invalid_path" end

    local path = string.gsub(value, "/", "\\")
    path = string.gsub(path, "^%.\\", "")
    local lowered = string.lower(path)
    local relative = nil
    for _, prefix in ipairs(ROOT_PREFIXES) do
        if string.sub(lowered, 1, #prefix) == prefix then
            relative = string.sub(path, #prefix + 1)
            break
        end
    end
    if not relative or relative == "" then return nil, "outside_root" end

    local segments = {}
    for segment in string.gmatch(relative, "[^\\]+") do
        if segment == "." or segment == ".." then return nil, "unsafe_path" end
        segments[#segments + 1] = segment
    end
    if #segments == 0 then return nil, "invalid_path" end

    local extension = string.match(string.lower(segments[#segments]), "%.([^%.\\]+)$")
    if not extension or not SUPPORTED_EXTENSIONS[extension] then
        return nil, "unsupported_extension"
    end

    relative = table.concat(segments, "\\")
    local directory = #segments > 1
        and table.concat(segments, "\\", 1, #segments - 1) or ""
    return {
        file = "VoiceController\\" .. relative,
        relativePath = relative,
        name = segments[#segments],
        extension = extension,
        directory = directory,
        groupDirectory = #segments > 1 and segments[1] or nil
    }
end

-- 解析 REFAudio 工作线程生成的 UTF-8 清单；尾标数量不匹配时拒绝半写文件。
function Catalog.parse_native_manifest(content)
    if type(content) ~= "string" or content == "" then
        return nil, "native_catalog_missing"
    end
    if not is_valid_utf8(content) then return nil, "native_catalog_invalid_encoding" end
    local lines = {}
    for line in string.gmatch(content, "[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if lines[1] ~= "REFAudioCatalog\t1" then
        return nil, "native_catalog_invalid_header"
    end
    local expected = tonumber(string.match(lines[#lines] or "", "^END\t(%d+)$"))
    if expected == nil or expected ~= #lines - 2 then
        return nil, "native_catalog_incomplete"
    end
    local paths = {}
    for index = 2, #lines - 1 do paths[#paths + 1] = lines[index] end
    return paths
end

-- 扫描并生成确定性目录快照；所有枚举异常都转成诊断，避免帧回调因单个模式失败而中断。
function Catalog.scan(glob_fn, captured_at, patterns)
    local entries = {}
    local errors = {}
    local seen = {}
    local stats = {
        returned = 0,
        accepted = 0,
        duplicates = 0,
        invalid = 0,
        outsideRoot = 0,
        unsupported = 0
    }

    if type(glob_fn) ~= "function" then
        add_error(errors, nil, "glob_unavailable")
    else
        for _, pattern in ipairs(patterns or Catalog.DEFAULT_PATTERNS) do
            local ok, paths = pcall(glob_fn, pattern)
            if not ok then
                add_error(errors, pattern, "glob_failed", paths)
            elseif type(paths) ~= "table" then
                add_error(errors, pattern, "glob_invalid_result", type(paths))
            else
                for _, path in ipairs(paths) do
                    stats.returned = stats.returned + 1
                    local entry, reason = normalize_path(path)
                    if entry then
                        local key = string.lower(entry.file)
                        if seen[key] then
                            stats.duplicates = stats.duplicates + 1
                        else
                            seen[key] = true
                            entries[#entries + 1] = entry
                        end
                    elseif reason == "outside_root" then
                        stats.outsideRoot = stats.outsideRoot + 1
                    elseif reason == "unsupported_extension" then
                        stats.unsupported = stats.unsupported + 1
                    else
                        stats.invalid = stats.invalid + 1
                    end
                end
            end
        end
    end

    table.sort(entries, function(left, right)
        local left_key = string.lower(left.file)
        local right_key = string.lower(right.file)
        if left_key == right_key then return left.file < right.file end
        return left_key < right_key
    end)
    stats.accepted = #entries

    return {
        schemaVersion = 1,
        capturedAt = captured_at,
        root = "VoiceController",
        count = #entries,
        files = entries,
        errors = errors,
        stats = stats
    }
end

return Catalog
