// 多客户端邮箱仅由音频工作线程轮询；客户端通道与旧入口完全隔离。
// 每客户端一个未确认请求，ID 单调递增，最近结果固定保留 64 条。
struct MailboxClient {
    std::map<std::uint32_t, AudioChannel> channels;
    std::map<std::uint32_t, std::string> states;
    std::map<std::uint32_t, std::string> errors;
    std::map<std::string, std::pair<std::string, std::string>> results;
    std::vector<std::string> order;
    std::string session, last_snapshot, last_state;
    std::vector<std::string> retired_sessions;
    unsigned long long highest{};
};

// 严格 ASCII 标识避免路径转义；输入数字完整解析且拒绝非有限浮点。
bool mailbox_id(const std::string& id) {
    return !id.empty() && id.size() <= 64 && std::all_of(id.begin(), id.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
    });
}
bool mailbox_number(const std::string& text, double lo, double hi, double& number) {
    try { std::size_t count{}; number = std::stod(text, &count); return count == text.size() && std::isfinite(number) && number >= lo && number <= hi; }
    catch (...) { return false; }
}
bool mailbox_request_id(const std::string& text, unsigned long long& id) {
    if (text.empty() || text.size() > 20 || text[0] == '0' || text.find_first_not_of("0123456789") != std::string::npos) return false;
    try { id = std::stoull(text); return true; } catch (...) { return false; }
}

// 状态逐行包含 boot/session/local_channel/state/seconds/error，自然结束保留 ended。
void write_mailbox_state(BassApi& bass, MailboxClient& client, const std::filesystem::path& dir, const std::string& boot) {
    std::ostringstream out;
    for (auto& [id, state] : client.states) {
        double seconds = 0;
        auto it = client.channels.find(id);
        if (it != client.channels.end()) {
            seconds = bass.bytes_to_seconds(it->second.stream, bass.position(it->second.stream, BASS_POS_BYTE));
            auto active = bass.active(it->second.stream);
            if (!active || (it->second.max_duration > 0 && seconds >= it->second.max_duration)) {
                free_channel(bass, it->second); client.channels.erase(it); state = "ended";
            } else state = active == BASS_ACTIVE_PAUSED ? "paused" : "playing";
        }
        out << boot << '\t' << client.session << '\t' << id << '\t' << state << '\t' << seconds << '\t' << (client.errors[id].empty() ? "-" : client.errors[id]) << '\n';
    }
    if (out.str() != client.last_state && write_text_atomic(dir / L"state.txt", out.str())) client.last_state = out.str();
}

// 邮箱快照关闭句柄后处理；每个入口独立去重，错误不能阻塞其他客户端。
void poll_mailboxes(BassApi& bass, const std::filesystem::path& base, const std::filesystem::path& data,
    const std::string& boot, std::map<std::string, MailboxClient>& clients, std::size_t legacy_count) {
    std::error_code ec;
    std::filesystem::directory_iterator directories(base / L"clients", ec);
    if (ec) return;
    std::size_t visited = 0;
    for (const auto& entry : directories) {
        if (++visited > 64) break;
        if (!entry.is_directory(ec) || entry.is_symlink(ec)) continue;
        auto name = wide_to_utf8(entry.path().filename().wstring());
        if (!mailbox_id(name)) continue;
        auto path = entry.path() / L"command.txt";
        auto size = std::filesystem::file_size(path, ec);
        if (ec) { ec.clear(); continue; }
        if (clients.find(name) == clients.end() && clients.size() >= 16) {
            write_text_atomic(entry.path() / L"response.txt", boot + "\t-\t0\t0\terror\tclient_limit\n"); continue;
        }
        auto& client = clients[name];
        if (size > 8192) { write_text_atomic(entry.path() / L"response.txt", boot + "\t-\t0\t0\terror\tcommand_too_large\n"); continue; }
        std::string body;
        { std::ifstream file(path, std::ios::binary); if (file) body.assign(std::istreambuf_iterator<char>(file), {}); }
        if (body.empty() || body == client.last_snapshot) { write_mailbox_state(bass, client, entry.path(), boot); continue; }
        client.last_snapshot = body;
        auto fields = split_tabs(body);
        std::string error;
        std::uint32_t local = 0;
        unsigned long long request = 0;
        if (fields.size() < 5 || body.find_first_of("\r\n\0", 0, 3) != std::string::npos ||
            !mailbox_id(fields[0]) || !mailbox_id(fields[1]) || !mailbox_request_id(fields[2], request) || !parse_channel_id(fields[4], local)) {
            write_text_atomic(entry.path() / L"response.txt", boot + "\t-\t0\t0\terror\tinvalid_command\n"); continue;
        }
        auto key = fields[1] + "/" + fields[2];
        auto prefix = fields[0] + "\t" + fields[1] + "\t" + fields[2] + "\t" + fields[4] + "\t";
        auto cached = client.results.find(key);
        if (fields[0] != boot) error = "boot_mismatch";
        else if (cached != client.results.end()) {
            write_text_atomic(entry.path() / L"response.txt", cached->second.first == body ? cached->second.second : prefix + "error\trequest_conflict\n");
            write_mailbox_state(bass, client, entry.path(), boot); continue;
        } else if (client.session != fields[1]) {
            if (std::find(client.retired_sessions.begin(), client.retired_sessions.end(), fields[1]) != client.retired_sessions.end()) error = "stale_session";
            else if (client.retired_sessions.size() >= 64) error = "session_limit";
            else {
                if (!client.session.empty()) client.retired_sessions.push_back(client.session);
                for (auto& [_, ch] : client.channels) free_channel(bass, ch);
                client.channels.clear(); client.states.clear(); client.errors.clear(); client.session = fields[1]; client.highest = 0;
            }
        }
        if (error.empty() && request <= client.highest) error = "stale_request";
        if (error.empty()) {
            client.highest = request;
            const auto& action = fields[3];
            auto found = client.channels.find(local);
            double volume, speed, duration;
            if (action == "load" && fields.size() == 9) {
                auto relative = std::filesystem::path(utf8_to_wide(fields[5]));
                int valid_utf8 = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, fields[5].data(), static_cast<int>(fields[5].size()), nullptr, 0);
                bool unsafe = !valid_utf8 || !is_safe_relative_path(relative) || relative.has_root_name() || fields[5].find(':') != std::string::npos;
                auto root = std::filesystem::weakly_canonical(data, ec);
                auto resolved = std::filesystem::weakly_canonical(data / relative, ec);
                auto within = resolved.lexically_relative(root);
                if (unsafe || ec || !is_safe_relative_path(within)) error = "invalid_path";
                else if (!std::filesystem::is_regular_file(resolved, ec)) error = "file_not_found";
                else if (!mailbox_number(fields[6], 0, 5, volume) || !mailbox_number(fields[7], .1, 8, speed) || !mailbox_number(fields[8], 0, 3600, duration)) error = "invalid_parameter";
                else {
                    std::size_t count = legacy_count;
                    for (const auto& [_, c] : clients) count += c.channels.size();
                    if ((found == client.channels.end() && count >= MAX_CHANNELS) || (client.states.find(local) == client.states.end() && client.states.size() >= 64)) error = "channel_limit";
                    else {
                        auto& channel = client.channels[local];
                        if (!load_channel(bass, data, fields[5], static_cast<float>(volume), static_cast<float>(speed), duration, false, nullptr, 1, 10000, channel, error)) client.channels.erase(local);
                        client.states[local] = error.empty() ? "playing" : "error";
                    }
                }
            } else if (action == "stop_client" && fields.size() == 5) {
                for (auto& [id, ch] : client.channels) { free_channel(bass, ch); client.states[id] = "stopped"; }
                client.channels.clear();
            } else if (action == "status" && fields.size() == 5) {
                if (client.states.find(local) == client.states.end()) error = "channel_unknown";
            } else if (action == "stop" && fields.size() == 5) {
                if (found != client.channels.end()) { free_channel(bass, found->second); client.channels.erase(found); }
                if (client.states.find(local) != client.states.end()) client.states[local] = "stopped";
            } else if (action == "volume" && fields.size() == 6) {
                if (found == client.channels.end()) error = "channel_unknown";
                else if (!mailbox_number(fields[5], 0, 5, volume)) error = "invalid_parameter";
                else if (!bass.set_attribute(found->second.stream, BASS_ATTRIB_VOL, static_cast<float>(volume))) error = "bass_" + std::to_string(bass.error());
                else found->second.volume = static_cast<float>(volume);
            } else error = "unsupported_command";
        }
        if (client.states.find(local) != client.states.end()) client.errors[local] = error;
        auto response = prefix + (error.empty() ? "ok\t-\n" : "error\t" + error + "\n");
        if (fields[0] == boot) {
            client.results[key] = {body, response}; client.order.push_back(key);
            if (client.order.size() > 64) { client.results.erase(client.order.front()); client.order.erase(client.order.begin()); }
        }
        write_text_atomic(entry.path() / L"response.txt", response);
        write_mailbox_state(bass, client, entry.path(), boot);
    }
}