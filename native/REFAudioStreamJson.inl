// PCM 邮箱的有界 JSON 解析器；仅音频工作线程调用，不接受半写、重复键或非有限数字。
// 不依赖游戏 SDK；每份正文最多 8 KiB、嵌套最多 16 层，未知合法字段允许保留。
struct StreamJson {
    enum Kind { Null, Number, String, Boolean, Array, Object } kind = Null;
    double number{};
    bool boolean{};
    std::string string;
    std::vector<StreamJson> array;
    std::map<std::string, StreamJson> object;
    const StreamJson* field(const char* key) const {
        auto it = object.find(key); return it == object.end() ? nullptr : &it->second;
    }
    bool text(const char* key, std::string& out) const {
        auto p = field(key); if (!p || p->kind != String) return false; out = p->string; return true;
    }
    bool numeric(const char* key, double& out, double lo, double hi, bool integer = false) const {
        auto p = field(key);
        if (!p || p->kind != Number || p->number < lo || p->number > hi ||
            (integer && p->number != std::floor(p->number))) return false;
        out = p->number; return true;
    }
    bool vector(const char* key, BassVector& out) const {
        auto p = field(key); if (!p || p->kind != Array || p->array.size() != 3) return false;
        float v[3]{};
        for (int i = 0; i < 3; ++i) {
            if (p->array[i].kind != Number || std::abs(p->array[i].number) > 1000000) return false;
            v[i] = static_cast<float>(p->array[i].number);
        }
        out = {v[0], v[1], v[2]}; return true;
    }
};

class StreamJsonParser {
    const std::string& body;
    std::size_t at{};
    void space() { while (at < body.size() && (body[at]==' ' || body[at]=='\t' || body[at]=='\r' || body[at]=='\n')) ++at; }
    bool take(char c) { space(); if (at == body.size() || body[at] != c) return false; ++at; return true; }
    bool hex4(unsigned& out) {
        out = 0;
        for (int i = 0; i < 4; ++i) {
            if (at == body.size()) return false;
            char c = body[at++]; int n = c >= '0' && c <= '9' ? c-'0' :
                c >= 'a' && c <= 'f' ? c-'a'+10 : c >= 'A' && c <= 'F' ? c-'A'+10 : -1;
            if (n < 0) return false; out = out*16 + n;
        }
        return true;
    }
    bool quoted(std::string& out) {
        if (!take('"')) return false;
        while (at < body.size()) {
            unsigned char c = body[at++];
            if (c == '"') return true;
            if (c < 32) return false;
            if (c != '\\') { out.push_back(c); continue; }
            if (at == body.size()) return false;
            switch (body[at++]) {
            case '"': out += '"'; break; case '\\': out += '\\'; break; case '/': out += '/'; break;
            case 'b': out += '\b'; break; case 'f': out += '\f'; break;
            case 'n': out += '\n'; break; case 'r': out += '\r'; break; case 't': out += '\t'; break;
            case 'u': {
                unsigned code{}; if (!hex4(code)) return false;
                std::wstring wide(1, static_cast<wchar_t>(code));
                if (code >= 0xd800 && code <= 0xdbff) {
                    if (body.compare(at, 2, "\\u") != 0) return false; at += 2;
                    unsigned low{}; if (!hex4(low) || low < 0xdc00 || low > 0xdfff) return false;
                    wide.push_back(static_cast<wchar_t>(low));
                } else if (code >= 0xdc00 && code <= 0xdfff) return false;
                out += wide_to_utf8(wide); break;
            }
            default: return false;
            }
        }
        return false;
    }
    bool value(StreamJson& out, int depth) {
        space(); if (depth > 16 || at == body.size()) return false;
        char c = body[at];
        if (c == '"') { out.kind = StreamJson::String; return quoted(out.string); }
        if (c == '{') {
            out.kind = StreamJson::Object; ++at; if (take('}')) return true;
            do {
                std::string key; StreamJson child;
                if (!quoted(key) || !take(':') || !value(child, depth+1) ||
                    !out.object.emplace(key, std::move(child)).second) return false;
                if (take('}')) return true;
            } while (take(','));
            return false;
        }
        if (c == '[') {
            out.kind = StreamJson::Array; ++at; if (take(']')) return true;
            do {
                StreamJson child; if (!value(child, depth+1)) return false;
                out.array.push_back(std::move(child)); if (take(']')) return true;
            } while (take(','));
            return false;
        }
        for (const char* literal : {"true", "false", "null"}) {
            std::size_t size = std::strlen(literal);
            if (body.compare(at, size, literal) == 0) {
                at += size; out.kind = *literal == 'n' ? StreamJson::Null : StreamJson::Boolean;
                out.boolean = *literal == 't'; return true;
            }
        }
        auto begin = at;
        if (c == '-') ++at;
        if (at == body.size()) return false;
        if (body[at] == '0') ++at;
        else {
            if (body[at] < '1' || body[at] > '9') return false;
            while (at < body.size() && body[at] >= '0' && body[at] <= '9') ++at;
        }
        auto digits = [&]() {
            auto start = at; while (at < body.size() && body[at] >= '0' && body[at] <= '9') ++at;
            return at > start;
        };
        if (at < body.size() && body[at] == '.') { ++at; if (!digits()) return false; }
        if (at < body.size() && (body[at]=='e' || body[at]=='E')) {
            ++at; if (at < body.size() && (body[at]=='+' || body[at]=='-')) ++at;
            if (!digits()) return false;
        }
        try { out.number = std::stod(body.substr(begin, at-begin)); } catch (...) { return false; }
        out.kind = StreamJson::Number; return std::isfinite(out.number);
    }
public:
    explicit StreamJsonParser(const std::string& text) : body(text) {}
    bool parse(StreamJson& out) {
        if (body.empty() || body.size() > 8192 || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            body.data(), static_cast<int>(body.size()), nullptr, 0)) return false;
        if (!value(out, 0) || out.kind != StreamJson::Object) return false;
        space(); return at == body.size();
    }
};

// 固定上限读取完整控制文件；过大的文件只返回无效标记，避免读取线程内存无界增长。
static std::string read_stream_json(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary); if (!file) return {};
    char bytes[8193]; file.read(bytes, sizeof(bytes));
    return std::string(bytes, static_cast<std::size_t>(file.gcount()));
}
