// 流式 PCM 状态；push stream 和临时缓冲均由音频工作线程拥有。
struct PcmStream {
    AudioChannel channel;
    std::string request_id, session_id, directory;
    DWORD sample_rate{}, channels{};
    std::size_t prebuffer_bytes{}, buffered_bytes{}, received_bytes{}, consumed_bytes{};
    unsigned long long next_chunk{};
    unsigned long long command_id{};
    std::string last_command_text, last_response;
    std::string state = "starting", error;
    bool started{}, finished{}, stopped{};
    std::size_t received_chunks{}, consumed_chunks{};
};

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
    std::unique_ptr<PcmStream> stream;
};

// 严格 ASCII 标识避免路径转义。
static bool mailbox_id(const std::string& id);

static bool json_string(const std::string& text, const char* key, std::string& value) {
    const std::string marker = std::string("\"") + key + "\"";
    auto at = text.find(marker); if (at == std::string::npos) return false;
    at = text.find(':', at + marker.size()); if (at == std::string::npos) return false;
    at = text.find('"', at + 1); if (at == std::string::npos) return false;
    std::string result; bool escape = false;
    for (++at; at < text.size(); ++at) {
        char c = text[at]; if (escape) { result.push_back(c); escape = false; continue; }
        if (c == '\\') { escape = true; continue; }
        if (c == '"') { value = result; return true; } result.push_back(c);
    }
    return false;
}
static bool json_number(const std::string& text, const char* key, double& value) {
    const std::string marker = std::string("\"") + key + "\""; auto at = text.find(marker);
    if (at == std::string::npos) return false; at = text.find(':', at + marker.size()); if (at == std::string::npos) return false;
    ++at; while (at < text.size() && std::isspace(static_cast<unsigned char>(text[at]))) ++at;
    try { std::size_t count{}; value = std::stod(text.substr(at), &count); return count > 0 && std::isfinite(value); } catch (...) { return false; }
}
static bool json_safe_id(const std::string& value) { return mailbox_id(value) && value.find('.') == std::string::npos; }
static std::string stream_response(const std::string& boot, const std::string& session,
    const std::string& request, unsigned long long command, const std::string& status, const std::string& error,
    std::size_t consumed, std::size_t buffered) {
    std::ostringstream out; out << "{\"boot_id\":\"" << boot << "\",\"session_id\":\"" << session
        << "\",\"request_id\":\"" << request << "\",\"command_id\":" << command
        << ",\"status\":\"" << status << "\",\"consumed_bytes\":" << consumed
        << ",\"buffered_bytes\":" << buffered << ",\"error_code\":"
        << (error.empty() ? "null" : ("\"" + error + "\"")) << "}\n"; return out.str();
}

// 原子写入流状态，供 DeepSeekCat 区分 buffering/playing/draining/ended。
static void write_pcm_state(BassApi& bass, PcmStream& stream, const std::filesystem::path& dir,
    const std::string& boot) {
    double seconds = stream.channel.stream ? bass.bytes_to_seconds(stream.channel.stream,
        bass.position(stream.channel.stream, BASS_POS_BYTE)) : 0.0;
    std::ostringstream out; out << "{\"boot_id\":\"" << boot << "\",\"session_id\":\"" << stream.session_id
        << "\",\"request_id\":\"" << stream.request_id << "\",\"state\":\"" << stream.state
        << "\",\"received_chunks\":" << stream.received_chunks << ",\"consumed_chunks\":" << stream.consumed_chunks
        << ",\"received_bytes\":" << stream.received_bytes << ",\"consumed_bytes\":" << stream.consumed_bytes
        << ",\"buffered_bytes\":" << stream.buffered_bytes << ",\"duration_seconds\":" << seconds
        << ",\"last_chunk_index\":" << (stream.next_chunk ? stream.next_chunk - 1 : 0)
        << ",\"error_code\":" << (stream.error.empty() ? "null" : ("\"" + stream.error + "\"")) << "}\n";
    write_text_atomic(dir / L"stream_state.json", out.str());
}

// 处理客户端的流式 JSON 文件；每轮最多消费一个命令和一个 chunk，避免阻塞旧入口。
static void poll_pcm_stream(BassApi& bass, const std::filesystem::path& client_dir,
    const std::filesystem::path& data_dir, const std::string& boot, MailboxClient& client) {
    auto start_path = client_dir / L"stream_start.json";
    auto command_path = client_dir / L"stream_command.json";
    std::string start_text, command_text;
    { std::ifstream f(start_path, std::ios::binary); if (f) start_text.assign(std::istreambuf_iterator<char>(f), {}); }
    { std::ifstream f(command_path, std::ios::binary); if (f) command_text.assign(std::istreambuf_iterator<char>(f), {}); }
    if (!start_text.empty() && !client.stream) {
        std::string request, session, format, directory; double channel{}, rate{}, chans{}, bits{}, volume{}, speed{}, duration{}, prebuffer{};
        bool valid = json_string(start_text, "boot_id", format) && format == boot && json_string(start_text, "session_id", session)
            && json_string(start_text, "request_id", request) && json_string(start_text, "format", format) && format == "pcm_s16le"
            && json_string(start_text, "stream_directory", directory) && json_safe_id(session) && json_safe_id(request)
            && json_number(start_text, "local_channel", channel) && json_number(start_text, "sample_rate", rate)
            && json_number(start_text, "channels", chans) && json_number(start_text, "bits_per_sample", bits)
            && json_number(start_text, "volume", volume) && json_number(start_text, "speed", speed)
            && json_number(start_text, "max_duration_seconds", duration) && json_number(start_text, "prebuffer_ms", prebuffer)
            && channel >= 0 && channel <= UINT32_MAX && rate >= 8000 && rate <= 96000 && (chans == 1 || chans == 2)
            && bits == 16 && volume >= 0 && volume <= 5 && speed >= .1 && speed <= 8 && duration >= 0 && duration <= 3600
            && prebuffer >= 80 && prebuffer <= 500 && directory.find("..") == std::string::npos && directory.find(':') == std::string::npos;
        if (valid) {
            auto stream = std::make_unique<PcmStream>(); stream->request_id = request; stream->session_id = session; stream->directory = directory;
            stream->sample_rate = static_cast<DWORD>(rate); stream->channels = static_cast<DWORD>(chans);
            stream->prebuffer_bytes = static_cast<std::size_t>(rate * chans * 2 * prebuffer / 1000.0);
            stream->state = "buffering";
            stream->channel.volume = static_cast<float>(volume); stream->channel.speed = static_cast<float>(speed); stream->channel.max_duration = duration;
            stream->channel.stream = bass.create_push_stream(stream->sample_rate, stream->channels, BASS_SAMPLE_OVER_VOL, nullptr, nullptr);
            if (!stream->channel.stream) { stream->state = "error"; stream->error = "bass_create_failed"; }
            else client.stream = std::move(stream);
        }
    }
    if (client.stream) {
        auto& stream = *client.stream;
        if (!command_text.empty()) {
            std::string command_boot, command_session, request, action, file; double command_id_num{}, chunk_num{}, bytes_num{};
            bool valid = json_string(command_text, "boot_id", command_boot) && command_boot == boot
                && json_string(command_text, "session_id", command_session) && command_session == stream.session_id
                && json_string(command_text, "request_id", request) && request == stream.request_id
                && json_string(command_text, "action", action) && json_number(command_text, "command_id", command_id_num)
                && command_id_num >= 1 && command_id_num == std::floor(command_id_num);
            unsigned long long command_id = valid ? static_cast<unsigned long long>(command_id_num) : 0;
            if (valid && command_id == stream.command_id) {
                if (command_text == stream.last_command_text) { write_text_atomic(client_dir / L"stream_response.json", stream.last_response); command_text.clear(); }
                else { valid = false; }
            }
            std::string error;
            if (command_text.empty()) error.clear();
            else if (!valid) error = "request_conflict";
            else if (action == "chunk") {
                valid = json_number(command_text, "chunk_index", chunk_num) && chunk_num >= 1
                    && chunk_num == std::floor(chunk_num) && json_string(command_text, "file", file)
                    && json_number(command_text, "bytes", bytes_num) && bytes_num >= 1 && bytes_num <= 1048576;
                if (!valid) error = "invalid_parameter";
                else if (static_cast<unsigned long long>(chunk_num) != stream.next_chunk + 1) error = "chunk_out_of_order";
                else if (static_cast<std::size_t>(bytes_num) > 8 * 1024 * 1024 - stream.buffered_bytes) error = "buffer_full";
                else {
                    auto relative = std::filesystem::path(utf8_to_wide(file));
                    auto root = std::filesystem::weakly_canonical(data_dir);
                    auto resolved = std::filesystem::weakly_canonical(data_dir / relative);
                    auto within = resolved.lexically_relative(root);
                    std::vector<unsigned char> data;
                    if (file.find("..") != std::string::npos || file.find(':') != std::string::npos || !is_safe_relative_path(within)) error = "invalid_path";
                    else { std::ifstream chunk(resolved, std::ios::binary); if (!chunk) error = "file_not_found"; else data.assign(std::istreambuf_iterator<char>(chunk), {}); }
                    if (error.empty() && data.size() != static_cast<std::size_t>(bytes_num)) error = "io_error";
                    if (error.empty() && data.size() % (stream.channels * 2) != 0) error = "invalid_parameter";
                    if (error.empty()) {
                        auto accepted = bass.put_data(stream.channel.stream, data.data(), static_cast<DWORD>(data.size()));
                        if (accepted == DWORD(-1)) error = "bass_create_failed";
                        else { stream.next_chunk = static_cast<unsigned long long>(chunk_num); stream.received_chunks++; stream.received_bytes += data.size(); stream.buffered_bytes += data.size(); }
                    }
                }
            } else if (action == "finish") {
                stream.finished = true;
                if (!stream.started && stream.buffered_bytes > 0) {
                    if (!bass.play(stream.channel.stream, TRUE)) error = "bass_play_failed";
                    else { stream.started = true; stream.state = "draining"; }
                } else stream.state = stream.started ? "draining" : "ended";
                bass.put_data(stream.channel.stream, nullptr, 0);
            } else if (action == "stop") {
                stream.stopped = true; stream.state = "stopped"; free_channel(bass, stream.channel); stream.buffered_bytes = 0;
            } else if (action == "start") {
                // stream_start.json 已完成播放器创建；start 只确认当前流进入 buffering。
                if (stream.state == "error" || stream.stopped) error = "stream_not_started";
            } else error = "unsupported_command";
            stream.command_id = command_id;
            if (error.empty() && action == "chunk" && !stream.started && stream.buffered_bytes >= stream.prebuffer_bytes) {
                if (!bass.set_attribute(stream.channel.stream, BASS_ATTRIB_VOL, stream.channel.volume)
                    || !bass.play(stream.channel.stream, TRUE)) error = "bass_play_failed";
                else { stream.started = true; stream.state = "playing"; }
            }
            if (!error.empty()) { stream.error = error; stream.state = "error"; }
            auto response = stream_response(boot, stream.session_id, stream.request_id, command_id,
                error.empty() ? "ok" : "error", error, stream.consumed_bytes, stream.buffered_bytes);
            stream.last_command_text = command_text; stream.last_response = response;
            write_text_atomic(client_dir / L"stream_response.json", response);
        }
        if (stream.channel.stream && stream.started) {
            auto active = bass.active(stream.channel.stream);
            if (stream.finished && !active) { stream.state = "ended"; free_channel(bass, stream.channel); }
            else if (stream.finished) stream.state = "draining";
            else if (active == BASS_ACTIVE_PLAYING) stream.state = "playing";
        }
        write_pcm_state(bass, stream, client_dir, boot);
        if (stream.state == "ended" || stream.state == "stopped" || stream.state == "error") client.stream.reset();
    }
}

// 输入数字完整解析且拒绝非有限浮点。
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

// 独立邮箱的 3D 坐标只接受有限数值，防止 NaN/无穷值进入 BASS 的空间计算。
bool mailbox_vector(const std::vector<std::string>& fields, std::size_t index,
    BassVector& result, double limit) {
    if (fields.size() <= index + 2) return false;
    double values[3]{};
    for (int offset = 0; offset < 3; ++offset) {
        try {
            std::size_t count{};
            values[offset] = std::stod(fields[index + offset], &count);
            if (count != fields[index + offset].size() || !std::isfinite(values[offset]) ||
                std::abs(values[offset]) > limit) return false;
        } catch (...) { return false; }
    }
    result = {static_cast<float>(values[0]), static_cast<float>(values[1]),
        static_cast<float>(values[2])};
    return true;
}

// 监听器朝向必须非零、近似垂直；归一化后交给 BASS，坐标更新不重新加载流。
bool mailbox_basis(BassVector& front, BassVector& top) {
    auto length = [](const BassVector& v) { return std::sqrt(v.x*v.x + v.y*v.y + v.z*v.z); };
    const float fl = length(front), tl = length(top);
    if (fl < .001f || tl < .001f || std::abs(front.x*top.x + front.y*top.y + front.z*top.z) / (fl*tl) > .15f) return false;
    front = {front.x/fl, front.y/fl, front.z/fl};
    top = {top.x/tl, top.y/tl, top.z/tl};
    return true;
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
        poll_pcm_stream(bass, entry.path(), data, boot, client);
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
            double volume, speed, duration, reference_distance, max_distance;
            BassVector source{}, listener{}, front{}, top{};
            const bool spatial_load = action == "load3d";
            const bool valid_load_shape = (action == "load" && fields.size() == 9) ||
                (spatial_load && fields.size() == 23);
            if (valid_load_shape) {
                auto relative = std::filesystem::path(utf8_to_wide(fields[5]));
                int valid_utf8 = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, fields[5].data(), static_cast<int>(fields[5].size()), nullptr, 0);
                bool unsafe = !valid_utf8 || !is_safe_relative_path(relative) || relative.has_root_name() || fields[5].find(':') != std::string::npos;
                auto root = std::filesystem::weakly_canonical(data, ec);
                auto resolved = std::filesystem::weakly_canonical(data / relative, ec);
                auto within = resolved.lexically_relative(root);
                if (unsafe || ec || !is_safe_relative_path(within)) error = "invalid_path";
                else if (!std::filesystem::is_regular_file(resolved, ec)) error = "file_not_found";
                else if (!mailbox_number(fields[6], 0, 5, volume) || !mailbox_number(fields[7], .1, 8, speed) || !mailbox_number(fields[8], 0, 3600, duration)) error = "invalid_parameter";
                else if (spatial_load && (!mailbox_vector(fields, 9, source, 1000000) ||
                    !mailbox_number(fields[12], .01, 10000, reference_distance) ||
                    !mailbox_number(fields[13], .01, 1000000, max_distance) ||
                    max_distance < reference_distance || !mailbox_vector(fields, 14, listener, 1000000) ||
                    !mailbox_vector(fields, 17, front, 2) || !mailbox_vector(fields, 20, top, 2) || !mailbox_basis(front, top))) error = "invalid_parameter";
                else {
                    std::size_t count = legacy_count;
                    for (const auto& [_, c] : clients) count += c.channels.size();
                    if ((found == client.channels.end() && count >= MAX_CHANNELS) || (client.states.find(local) == client.states.end() && client.states.size() >= 64)) error = "channel_limit";
                    else {
                        auto& channel = client.channels[local];
                        if (spatial_load && !bass.set_listener_3d_position(&listener, nullptr, &front, &top)) error = "bass_listener_" + std::to_string(bass.error());
                        if (error.empty() && !load_channel(bass, data, fields[5], static_cast<float>(volume), static_cast<float>(speed), duration,
                            spatial_load, spatial_load ? &source : nullptr,
                            spatial_load ? static_cast<float>(reference_distance) : 1.0f,
                            spatial_load ? static_cast<float>(max_distance) : 10000.0f, channel, error)) client.channels.erase(local);
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
            // 旧 17 字段坐标命令仍兼容；18 字段版本额外把应用层距离增益写入当前 BASS 流。
            } else if (action == "position3d" && (fields.size() == 17 || fields.size() == 18)) {
                if (!mailbox_vector(fields, 5, source, 1000000) || !mailbox_vector(fields, 8, listener, 1000000) ||
                    !mailbox_vector(fields, 11, front, 2) || !mailbox_vector(fields, 14, top, 2) || !mailbox_basis(front, top) ||
                    (fields.size() == 18 && !mailbox_number(fields[17], 0, 5, volume))) error = "invalid_parameter";
                else if (found == client.channels.end()) {
                    // 坐标命令与自然结束可并发：已结束的自有通道确认成功，不误报播放失败。
                    if (client.states.find(local) == client.states.end() || client.states[local] != "ended") error = "channel_unknown";
                } else if (!found->second.spatial) error = "channel_not_spatial";
                else if (bass.active(found->second.stream)) {
                    if (!bass.set_3d_position(found->second.stream, &source, nullptr, nullptr) ||
                        !bass.set_listener_3d_position(&listener, nullptr, &front, &top) ||
                        (fields.size() == 18 && !bass.set_attribute(found->second.stream, BASS_ATTRIB_VOL, static_cast<float>(volume)))) error = "bass_position_" + std::to_string(bass.error());
                    else {
                        if (fields.size() == 18) found->second.volume = static_cast<float>(volume);
                        bass.apply_3d();
                    }
                }
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
