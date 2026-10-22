// 流式 PCM 状态；push stream 和临时缓冲均由音频工作线程拥有。
#include "REFAudioStreamJson.inl"
struct PcmStream {
    AudioChannel channel;
    std::string request_id, session_id, directory;
    DWORD sample_rate{}, channels{};
    std::size_t prebuffer_bytes{}, buffered_bytes{}, received_bytes{}, consumed_bytes{};
    unsigned long long next_chunk{};
    unsigned long long command_id{};
    std::string last_command_text, last_response, last_seen_command;
    std::string state = "starting", error;
    bool started{}, finished{}, stopped{};
    bool rebuffering{};
    std::size_t underrun_count{};
    ULONGLONG rebuffer_started{}, rebuffer_ms{};
    double last_seconds{};
    std::size_t received_chunks{}, consumed_chunks{};
    std::vector<std::size_t> chunk_ends;
    bool spatial{};
    BassVector source{}, listener{}, front{0,0,1}, top{0,1,0};
    float reference_distance{1.5f}, max_distance{40.0f};
    unsigned long long spatial_revision{};
    std::string last_spatial_text, applied_spatial_text, spatial_error;
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
    std::unique_ptr<PcmStream> terminal_stream;
    std::string last_stream_start;
    std::map<std::string, bool> pcm_requests;
    std::string pcm_session;
    std::vector<std::string> retired_pcm_sessions;
};

// 严格 ASCII 标识避免路径转义。
static bool mailbox_id(const std::string& id);
static bool mailbox_basis(BassVector& front, BassVector& top);

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
        bass.position(stream.channel.stream, BASS_POS_BYTE)) : stream.last_seconds;
    stream.last_seconds = seconds;
    stream.consumed_bytes = std::min(stream.received_bytes, static_cast<std::size_t>(std::max(0.0, seconds) * stream.sample_rate * stream.channels * 2));
    if(stream.state=="ended")stream.consumed_bytes=stream.received_bytes;
    stream.buffered_bytes = (stream.state=="stopped"||stream.state=="error")?0:stream.received_bytes - stream.consumed_bytes;
    stream.consumed_chunks = static_cast<std::size_t>(std::upper_bound(stream.chunk_ends.begin(),stream.chunk_ends.end(),stream.consumed_bytes)-stream.chunk_ends.begin());
    std::ostringstream out; out << "{\"boot_id\":\"" << boot << "\",\"session_id\":\"" << stream.session_id
        << "\",\"request_id\":\"" << stream.request_id << "\",\"state\":\"" << stream.state
        << "\",\"received_chunks\":" << stream.received_chunks << ",\"consumed_chunks\":" << stream.consumed_chunks
        << ",\"received_bytes\":" << stream.received_bytes << ",\"consumed_bytes\":" << stream.consumed_bytes
        << ",\"buffered_bytes\":" << stream.buffered_bytes << ",\"duration_seconds\":" << seconds
        << ",\"last_chunk_index\":" << stream.next_chunk
        << ",\"underrun_count\":" << stream.underrun_count
        << ",\"spatial\":" << (stream.spatial ? "true" : "false")
        << ",\"spatial_revision\":" << stream.spatial_revision
        << ",\"rebuffer_ms\":" << (stream.rebuffer_ms + (stream.rebuffering ? GetTickCount64()-stream.rebuffer_started : 0))
        << ",\"error_code\":" << (stream.error.empty() ? "null" : ("\"" + stream.error + "\"")) << "}\n";
    write_text_atomic(dir / L"stream_state.json", out.str());
}

// 空间快照回执独立于 PCM 命令确认；错误保留上一次有效位置和音量。
static void write_spatial_state(const std::filesystem::path& dir, const PcmStream& stream,
    const std::string& boot, const std::string& status, const std::string& error,
    unsigned long long observed) {
    std::ostringstream out;
    out << "{\"boot_id\":\"" << boot << "\",\"session_id\":\"" << stream.session_id
        << "\",\"request_id\":\"" << stream.request_id << "\",\"observed_revision\":" << observed
        << ",\"applied_revision\":" << stream.spatial_revision << ",\"status\":\"" << status
        << "\",\"error_code\":" << (error.empty() ? "null" : ("\"" + error + "\"")) << "}\n";
    write_text_atomic(dir / L"stream_spatial_state.json", out.str());
}

// 每轮只消费最新位置快照；不创建/重播/seek 流，也不占用 PCM command_id 或 chunk_index。
static void poll_stream_spatial(BassApi& bass, const std::filesystem::path& client_dir,
    const std::string& boot, PcmStream& stream) {
    const auto text = read_stream_json(client_dir / L"stream_spatial.json");
    if (text.empty()) return;
    if (text == stream.last_spatial_text) return;
    stream.last_spatial_text = text;
    StreamJson root; std::string json_boot, session, request;
    double revision{};
    bool valid = StreamJsonParser(text).parse(root) && root.text("boot_id", json_boot) && json_boot == boot
        && root.text("session_id", session) && session == stream.session_id
        && root.text("request_id", request) && request == stream.request_id
        && root.numeric("revision", revision, 1, 9007199254740991.0, true);
    const auto observed = valid ? static_cast<unsigned long long>(revision) : 0;
    if (!valid) { stream.spatial_error = "invalid_snapshot"; write_spatial_state(client_dir, stream, boot, "error", stream.spatial_error, observed); return; }
    if (stream.state == "ended" || stream.state == "stopped" || stream.state == "error") {
        write_spatial_state(client_dir, stream, boot, "inactive", {}, observed); return;
    }
    if (observed < stream.spatial_revision) { write_spatial_state(client_dir, stream, boot, "error", "stale_revision", observed); return; }
    if (observed == stream.spatial_revision) {
        stream.spatial_error = text == stream.applied_spatial_text ? "" : "revision_conflict";
        write_spatial_state(client_dir, stream, boot, stream.spatial_error.empty() ? "ok" : "error", stream.spatial_error, observed); return;
    }
    BassVector source{}, listener{}, front{}, top{}; double volume{};
    valid = stream.spatial && root.vector("source", source) && root.vector("listener", listener)
        && root.vector("front", front) && root.vector("top", top) && mailbox_basis(front, top)
        && root.numeric("volume", volume, 0, 5);
    if (!valid) { stream.spatial_error = stream.spatial ? "invalid_snapshot" : "stream_not_spatial"; write_spatial_state(client_dir, stream, boot, "error", stream.spatial_error, observed); return; }
    if (!bass.set_3d_position(stream.channel.stream, &source, nullptr, nullptr)
        || !bass.set_listener_3d_position(&listener, nullptr, &front, &top)
        || !bass.set_attribute(stream.channel.stream, BASS_ATTRIB_VOL, static_cast<float>(volume))) {
        stream.spatial_error = "bass_spatial_" + std::to_string(bass.error());
        // BASS 失败同样回滚，防止部分位置或增益留在设备中。
        bass.set_3d_position(stream.channel.stream, &stream.source, nullptr, nullptr);
        bass.set_listener_3d_position(&stream.listener, nullptr, &stream.front, &stream.top);
        bass.set_attribute(stream.channel.stream, BASS_ATTRIB_VOL, stream.channel.volume); bass.apply_3d();
        write_spatial_state(client_dir, stream, boot, "error", stream.spatial_error, observed); return;
    }
    stream.source = source; stream.listener = listener; stream.front = front; stream.top = top;
    stream.channel.volume = static_cast<float>(volume); stream.spatial_revision = observed; stream.spatial_error.clear();
    stream.applied_spatial_text = text;
    bass.apply_3d(); write_spatial_state(client_dir, stream, boot, "ok", {}, observed);
}

// 处理客户端的流式 JSON 文件；每轮最多消费一个命令和一个 chunk，避免阻塞旧入口。
static void poll_pcm_stream(BassApi& bass, const std::filesystem::path& client_dir,
    const std::filesystem::path& data_dir, const std::string& boot, MailboxClient& client,
    std::size_t channel_count) {
    auto start_path = client_dir / L"stream_start.json";
    auto command_path = client_dir / L"stream_command.json";
    std::string start_text, command_text;
    start_text = read_stream_json(start_path); command_text = read_stream_json(command_path);
    if (!start_text.empty() && !client.stream && start_text != client.last_stream_start) {
        client.last_stream_start = start_text;
        StreamJson root;
        std::string request, session, format, directory, start_boot, start_error;
        double channel{}, rate{}, chans{}, bits{}, volume{}, speed{}, duration{}, prebuffer{};
        BassVector source{}, listener{}, front{}, top{}; double reference{}, maximum{}; bool spatial{};
        bool valid = StreamJsonParser(start_text).parse(root) && root.text("boot_id", start_boot)
            && root.text("session_id", session) && root.text("request_id", request)
            && json_safe_id(session) && json_safe_id(request);
        if (valid && start_boot != boot) { start_error = "boot_mismatch"; valid = false; }
        valid = valid && root.text("format", format) && format == "pcm_s16le" && root.text("stream_directory", directory)
            && root.numeric("local_channel", channel, 0, UINT32_MAX, true) && root.numeric("sample_rate", rate, 8000, 96000, true)
            && root.numeric("channels", chans, 1, 2, true) && root.numeric("bits_per_sample", bits, 16, 16, true)
            && root.numeric("volume", volume, 0, 5) && root.numeric("speed", speed, .1, 8)
            && root.numeric("max_duration_seconds", duration, 0, 3600) && root.numeric("prebuffer_ms", prebuffer, 80, 500);
        if (auto p = root.field("spatial")) { valid = valid && p->kind == StreamJson::Boolean; spatial = p->boolean; }
        if (valid && spatial) {
            if (chans != 1) { valid = false; start_error = "spatial_requires_mono"; }
            else valid = root.vector("source", source) && root.vector("listener", listener) && root.vector("front", front)
                && root.vector("top", top) && mailbox_basis(front, top)
                && root.numeric("reference_distance", reference, .000001, 1000000)
                && root.numeric("max_distance", maximum, reference, 1000000);
        }
        std::error_code ec;
        auto relative = std::filesystem::path(utf8_to_wide(directory));
        auto data_root = std::filesystem::weakly_canonical(data_dir, ec);
        auto resolved = std::filesystem::weakly_canonical(data_dir / relative, ec);
        if (valid && (ec || directory.find('\0') != std::string::npos || directory.find(':') != std::string::npos
            || !is_safe_relative_path(relative) || !is_safe_relative_path(resolved.lexically_relative(data_root)))) {
            valid = false; start_error = "invalid_path";
        }
        auto key = session + "/" + request;
        if (valid && session != client.pcm_session && std::find(client.retired_pcm_sessions.begin(),
            client.retired_pcm_sessions.end(), session) != client.retired_pcm_sessions.end()) {
            valid = false; start_error = "stale_session";
        }
        if (valid && session != client.pcm_session && client.retired_pcm_sessions.size() >= 64) {
            valid = false; start_error = "session_limit";
        }
        if (valid && client.pcm_requests.count(key)) { valid = false; start_error = "request_conflict"; }
        if (valid && client.pcm_requests.size() >= 8192) { valid = false; start_error = "request_limit"; }
        if (valid && channel_count >= MAX_CHANNELS) { valid = false; start_error = "channel_limit"; }
        if (!valid) {
            if (!json_safe_id(session)) session = "-"; if (!json_safe_id(request)) request = "-";
            write_text_atomic(client_dir / L"stream_response.json", stream_response(boot, session, request, 0,
                "error", start_error.empty() ? "invalid_parameter" : start_error, 0, 0));
        }
        if (valid) {
            if (session != client.pcm_session) {
                if (!client.pcm_session.empty()) client.retired_pcm_sessions.push_back(client.pcm_session);
                client.pcm_session = session;
            }
            client.pcm_requests[key] = true;
            client.terminal_stream.reset();
            auto stream = std::make_unique<PcmStream>(); stream->request_id = request; stream->session_id = session; stream->directory = directory;
            stream->sample_rate = static_cast<DWORD>(rate); stream->channels = static_cast<DWORD>(chans);
            stream->prebuffer_bytes = static_cast<std::size_t>(rate * chans * 2 * prebuffer / 1000.0);
            stream->state = "buffering";
            stream->channel.volume = static_cast<float>(volume); stream->channel.speed = static_cast<float>(speed); stream->channel.max_duration = duration;
            stream->spatial = stream->channel.spatial = spatial;
            stream->source = source; stream->listener = listener; stream->front = front; stream->top = top;
            stream->reference_distance = static_cast<float>(reference); stream->max_distance = static_cast<float>(maximum);
            stream->channel.stream = bass.create_push_stream(stream->sample_rate, stream->channels,
                BASS_SAMPLE_OVER_VOL | (spatial ? BASS_SAMPLE_3D : 0),
                reinterpret_cast<void*>(static_cast<intptr_t>(-1)), nullptr);
            if (!stream->channel.stream) { stream->state = "error"; stream->error = "bass_create_failed"; }
            else if (!bass.set_attribute(stream->channel.stream,BASS_ATTRIB_FREQ,static_cast<float>(rate*speed))) {free_channel(bass,stream->channel);stream->state="error";stream->error="bass_create_failed";}
            else if (!bass.set_attribute(stream->channel.stream, BASS_ATTRIB_VOL, stream->channel.volume)) {
                stream->state = "error"; stream->error = "bass_gain_failed";
            } else if (spatial) {
                if (!bass.set_3d_attributes(stream->channel.stream, BASS_3DMODE_NORMAL, stream->reference_distance,
                    stream->max_distance, 360, 360, 0) || !bass.set_3d_position(stream->channel.stream, &source, nullptr, nullptr)
                    || !bass.set_listener_3d_position(&listener, nullptr, &front, &top)) {
                    stream->state = "error"; stream->error = "bass_spatial_init_failed";
                } else bass.apply_3d();
            }
            write_spatial_state(client_dir, *stream, boot, stream->state == "error" ? "inactive" : "ok", stream->error, 0);
            write_text_atomic(client_dir / L"stream_response.json", stream_response(boot, session, request, 0,
                stream->error.empty() ? "ok" : "error", stream->error, 0, 0));
            client.stream = std::move(stream);
        }
    }
    if (client.stream || client.terminal_stream) {
        auto& stream = client.stream ? *client.stream : *client.terminal_stream;
        // 先应用缓冲期最新增益，再执行可能起播的 chunk/finish，避免瞬间使用旧启动音量。
        poll_stream_spatial(bass, client_dir, boot, stream);
        if (!command_text.empty() && command_text != stream.last_seen_command) {
            stream.last_seen_command = command_text;
            StreamJson root;
            std::string command_boot, command_session, request, action, file; double command_id_num{}, chunk_num{}, bytes_num{};
            bool valid = StreamJsonParser(command_text).parse(root) && root.text("boot_id", command_boot) && command_boot == boot
                && root.text("session_id", command_session) && command_session == stream.session_id
                && root.text("request_id", request) && request == stream.request_id
                && root.text("action", action) && root.numeric("command_id", command_id_num, 1, 9007199254740991.0, true);
            unsigned long long command_id = valid ? static_cast<unsigned long long>(command_id_num) : 0;
            if (valid && command_id == stream.command_id) {
                if (command_text == stream.last_command_text) { write_text_atomic(client_dir / L"stream_response.json", stream.last_response); command_text.clear(); }
                else { valid = false; }
            }
            std::string error;
            if (command_text.empty()) error.clear();
            else if (!valid) error = "request_conflict";
            else if (command_id < stream.command_id) error = "stale_request";
            else if (!client.stream || stream.state == "error" || stream.state == "stopped" || stream.state == "ended") error = "stream_inactive";
            else if (action == "chunk" && stream.finished) error = "stream_already_finished";
            else if (action == "chunk" && stream.received_chunks >= 8192) error = "chunk_limit";
            else if (action == "chunk") {
                bool valid_chunk = root.numeric("chunk_index", chunk_num, 1, 8192, true) && root.text("file", file)
                    && root.numeric("bytes", bytes_num, 1, 1048576, true);
                if (!valid_chunk) error = "invalid_parameter";
                else if (static_cast<unsigned long long>(chunk_num) != stream.next_chunk + 1) error = "chunk_out_of_order";
                else if (static_cast<std::size_t>(bytes_num) > 8 * 1024 * 1024 - stream.buffered_bytes) error = "buffer_full";
                else {
                    auto relative = std::filesystem::path(utf8_to_wide(file));
                    std::error_code path_ec;
                    auto root_path = std::filesystem::weakly_canonical(data_dir, path_ec);
                    auto resolved = std::filesystem::weakly_canonical(data_dir / relative, path_ec);
                    auto within = resolved.lexically_relative(root_path);
                    std::vector<unsigned char> data;
                    if (path_ec || file.find('\0') != std::string::npos || file.find(':') != std::string::npos || !is_safe_relative_path(relative) || !is_safe_relative_path(within)) error = "invalid_path";
                    else if (std::filesystem::file_size(resolved, path_ec) != static_cast<std::size_t>(bytes_num) || path_ec) error = "io_error";
                    else { data.resize(static_cast<std::size_t>(bytes_num)); std::ifstream chunk(resolved, std::ios::binary);
                        if (!chunk.read(reinterpret_cast<char*>(data.data()), data.size())) error = "io_error"; }
                    if (error.empty() && data.size() != static_cast<std::size_t>(bytes_num)) error = "io_error";
                    if (error.empty() && data.size() % (stream.channels * 2) != 0) error = "invalid_parameter";
                    if (error.empty()) {
                        auto accepted = bass.put_data(stream.channel.stream, data.data(), static_cast<DWORD>(data.size()));
                        if (accepted == DWORD(-1)) error = "bass_create_failed";
                        else { stream.next_chunk = static_cast<unsigned long long>(chunk_num); stream.received_chunks++; stream.received_bytes += data.size(); stream.buffered_bytes += data.size();stream.chunk_ends.push_back(stream.received_bytes); }
                    }
                }
            } else if (action == "finish") {
                stream.finished = true;
                if (bass.put_data(stream.channel.stream, nullptr, 0x80000000u) == DWORD(-1)) error = "bass_finish_failed";
                if (!stream.started && stream.buffered_bytes > 0) {
                    if (!bass.set_attribute(stream.channel.stream, BASS_ATTRIB_VOL, stream.channel.volume) || !bass.play(stream.channel.stream, FALSE)) error = "bass_play_failed";
                    else { stream.started = true; stream.state = "draining"; }
                } else stream.state = stream.started ? "draining" : "ended";
                // BASS_STREAMPROC_END 封口 push stream；0 只是查询缓冲，不能表示 EOF。
            } else if (action == "stop") {
                stream.stopped = true; stream.state = "stopped"; free_channel(bass, stream.channel); stream.buffered_bytes = 0;
            } else if (action == "start") {
                // stream_start.json 已完成播放器创建；start 只确认当前流进入 buffering。
                if (stream.state == "error" || stream.stopped) error = "stream_not_started";
            } else error = "unsupported_command";
            const bool remember = valid && command_id > stream.command_id;
            if (remember) stream.command_id = command_id;
            if (error.empty() && action == "chunk" && !stream.started && stream.buffered_bytes >= stream.prebuffer_bytes) {
                if (!bass.set_attribute(stream.channel.stream, BASS_ATTRIB_VOL, stream.channel.volume)
                    || !bass.play(stream.channel.stream, FALSE)) error = "bass_play_failed";
                else { stream.started = true; stream.state = "playing"; }
            }
            if (error.rfind("bass_", 0) == 0) { stream.error = error; stream.state = "error"; }
            auto response = stream_response(boot, stream.session_id, stream.request_id, command_id,
                error.empty() ? "ok" : "error", error, stream.consumed_bytes, stream.buffered_bytes);
            if (!command_text.empty()) {
                if (remember) { stream.last_command_text = command_text; stream.last_response = response; }
                write_text_atomic(client_dir / L"stream_response.json", response);
            }
        }
        if (stream.channel.stream && stream.started) {
            auto active = bass.active(stream.channel.stream);
            stream.last_seconds = bass.bytes_to_seconds(stream.channel.stream, bass.position(stream.channel.stream, BASS_POS_BYTE));
            // 断流时暂停自动恢复，积攒至少一段缓冲后续播；不重置播放位置、不重新读取已消费块。
            // 按播放位置计算尚未播放的字节（含 push 队列和解码缓冲）；仅查询 push 队列会漏算解码数据。
            if (!stream.finished && !stream.rebuffering && active == BASS_ACTIVE_STALLED) {
                stream.underrun_count++; stream.rebuffering = true; stream.rebuffer_started = GetTickCount64();
                if (!bass.pause(stream.channel.stream)) { stream.state="error"; stream.error="bass_pause_failed"; }
            }
            if (stream.rebuffering && stream.error.empty()) {
                auto consumed = std::min(stream.received_bytes,static_cast<std::size_t>(std::max(0.0,stream.last_seconds)*stream.sample_rate*stream.channels*2));
                auto queued = stream.received_bytes-consumed;
                auto threshold = std::max(stream.prebuffer_bytes, static_cast<std::size_t>(stream.sample_rate*stream.channels*2*.5));
                if (stream.finished || queued >= threshold) {
                    if (!bass.play(stream.channel.stream,FALSE)) { stream.state="error"; stream.error="bass_play_failed"; }
                    else { stream.rebuffering=false; stream.rebuffer_ms+=GetTickCount64()-stream.rebuffer_started;active=bass.active(stream.channel.stream); }
                }
            }
            if (stream.channel.max_duration > 0 && stream.last_seconds >= stream.channel.max_duration) {
                stream.state = "ended"; free_channel(bass, stream.channel);
            }
            else if (!stream.error.empty()) stream.state="error";
            else if (stream.rebuffering) stream.state="buffering";
            else if (stream.finished && !active) { stream.state = "ended"; free_channel(bass, stream.channel); }
            else if (stream.finished) stream.state = "draining";
            else if (active == BASS_ACTIVE_PLAYING) stream.state = "playing";
        }
        poll_stream_spatial(bass, client_dir, boot, stream);
        if (client.stream) write_pcm_state(bass, stream, client_dir, boot);
        if (stream.state == "ended" || stream.state == "stopped" || stream.state == "error") {
            free_channel(bass, stream.channel);
            if (client.stream) {
                if (stream.spatial) write_spatial_state(client_dir, stream, boot, "inactive", {}, stream.spatial_revision);
                client.terminal_stream = std::move(client.stream);
            }
        }
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
        const bool has_command = !ec;
        ec.clear();
        if (!has_command && clients.find(name) == clients.end()
            && !std::filesystem::exists(entry.path() / L"stream_start.json", ec)) { ec.clear(); continue; }
        if (clients.find(name) == clients.end() && clients.size() >= 16) {
            write_text_atomic(entry.path() / L"response.txt", boot + "\t-\t0\t0\terror\tclient_limit\n");
            write_text_atomic(entry.path() / L"stream_response.json", stream_response(boot, "-", "-", 0, "error", "client_limit", 0, 0)); continue;
        }
        auto& client = clients[name];
        std::size_t channel_count = legacy_count;
        for (const auto& [_, owner] : clients) channel_count += owner.channels.size() + (owner.stream ? 1 : 0);
        poll_pcm_stream(bass, entry.path(), data, boot, client, channel_count);
        if (!has_command) { write_mailbox_state(bass, client, entry.path(), boot); continue; }
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
                    for (const auto& [_, c] : clients) count += c.channels.size() + (c.stream ? 1 : 0);
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
                if (client.stream) {
                    auto& stream = *client.stream; stream.state = "stopped"; stream.stopped = true;
                    write_pcm_state(bass, stream, entry.path(), boot); free_channel(bass, stream.channel);
                    if (stream.spatial) write_spatial_state(entry.path(), stream, boot, "inactive", {}, stream.spatial_revision);
                    client.terminal_stream = std::move(client.stream);
                }
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
