#define NOMINMAX
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {

constexpr DWORD BASS_UNICODE = 0x80000000;
constexpr DWORD BASS_DEVICE_3D = 4;
constexpr DWORD BASS_SAMPLE_MONO = 2;
constexpr DWORD BASS_SAMPLE_3D = 8;
constexpr DWORD BASS_POS_BYTE = 0;
constexpr DWORD BASS_ATTRIB_FREQ = 1;
constexpr DWORD BASS_ATTRIB_VOL = 2;
constexpr DWORD BASS_ACTIVE_PLAYING = 1;
constexpr DWORD BASS_ACTIVE_PAUSED = 3;
constexpr DWORD BASS_3DMODE_NORMAL = 0;
constexpr std::size_t MAX_CHANNELS = 32;

struct BassVector {
    float x{};
    float y{};
    float z{};
};

using BASS_Init_t = BOOL(WINAPI*)(int, DWORD, DWORD, HWND, void*);
using BASS_Free_t = BOOL(WINAPI*)();
using BASS_ErrorGetCode_t = int(WINAPI*)();
using BASS_StreamCreateFile_t = DWORD(WINAPI*)(BOOL, const void*,
    unsigned long long, unsigned long long, DWORD);
using BASS_StreamFree_t = BOOL(WINAPI*)(DWORD);
using BASS_ChannelPlay_t = BOOL(WINAPI*)(DWORD, BOOL);
using BASS_ChannelPause_t = BOOL(WINAPI*)(DWORD);
using BASS_ChannelStop_t = BOOL(WINAPI*)(DWORD);
using BASS_ChannelIsActive_t = DWORD(WINAPI*)(DWORD);
using BASS_ChannelGetPosition_t = unsigned long long(WINAPI*)(DWORD, DWORD);
using BASS_ChannelBytes2Seconds_t = double(WINAPI*)(DWORD,
    unsigned long long);
using BASS_ChannelSeconds2Bytes_t = unsigned long long(WINAPI*)(DWORD, double);
using BASS_ChannelSetPosition_t = BOOL(WINAPI*)(DWORD, unsigned long long,
    DWORD);
using BASS_ChannelGetAttribute_t = BOOL(WINAPI*)(DWORD, DWORD, float*);
using BASS_ChannelSetAttribute_t = BOOL(WINAPI*)(DWORD, DWORD, float);
using BASS_ChannelSet3DAttributes_t = BOOL(WINAPI*)(DWORD, int, float, float,
    int, int, float);
using BASS_ChannelSet3DPosition_t = BOOL(WINAPI*)(DWORD, const BassVector*,
    const BassVector*, const BassVector*);
using BASS_Set3DPosition_t = BOOL(WINAPI*)(const BassVector*, const BassVector*,
    const BassVector*, const BassVector*);
using BASS_Apply3D_t = void(WINAPI*)();

struct BassApi {
    HMODULE module{};
    BASS_Init_t init{};
    BASS_Free_t free{};
    BASS_ErrorGetCode_t error{};
    BASS_StreamCreateFile_t create_stream{};
    BASS_StreamFree_t free_stream{};
    BASS_ChannelPlay_t play{};
    BASS_ChannelPause_t pause{};
    BASS_ChannelStop_t stop{};
    BASS_ChannelIsActive_t active{};
    BASS_ChannelGetPosition_t position{};
    BASS_ChannelBytes2Seconds_t bytes_to_seconds{};
    BASS_ChannelSeconds2Bytes_t seconds_to_bytes{};
    BASS_ChannelSetPosition_t set_position{};
    BASS_ChannelGetAttribute_t get_attribute{};
    BASS_ChannelSetAttribute_t set_attribute{};
    BASS_ChannelSet3DAttributes_t set_3d_attributes{};
    BASS_ChannelSet3DPosition_t set_3d_position{};
    BASS_Set3DPosition_t set_listener_3d_position{};
    BASS_Apply3D_t apply_3d{};

    bool load(const std::filesystem::path& file) {
        module = LoadLibraryW(file.c_str());
        if (!module) return false;
#define BASS_LOAD(member, symbol) \
        member = reinterpret_cast<decltype(member)>(GetProcAddress(module, symbol)); \
        if (!member) return false
        BASS_LOAD(init, "BASS_Init");
        BASS_LOAD(free, "BASS_Free");
        BASS_LOAD(error, "BASS_ErrorGetCode");
        BASS_LOAD(create_stream, "BASS_StreamCreateFile");
        BASS_LOAD(free_stream, "BASS_StreamFree");
        BASS_LOAD(play, "BASS_ChannelPlay");
        BASS_LOAD(pause, "BASS_ChannelPause");
        BASS_LOAD(stop, "BASS_ChannelStop");
        BASS_LOAD(active, "BASS_ChannelIsActive");
        BASS_LOAD(position, "BASS_ChannelGetPosition");
        BASS_LOAD(bytes_to_seconds, "BASS_ChannelBytes2Seconds");
        BASS_LOAD(seconds_to_bytes, "BASS_ChannelSeconds2Bytes");
        BASS_LOAD(set_position, "BASS_ChannelSetPosition");
        BASS_LOAD(get_attribute, "BASS_ChannelGetAttribute");
        BASS_LOAD(set_attribute, "BASS_ChannelSetAttribute");
        BASS_LOAD(set_3d_attributes, "BASS_ChannelSet3DAttributes");
        BASS_LOAD(set_3d_position, "BASS_ChannelSet3DPosition");
        BASS_LOAD(set_listener_3d_position, "BASS_Set3DPosition");
        BASS_LOAD(apply_3d, "BASS_Apply3D");
#undef BASS_LOAD
        return true;
    }
};

// 单个播放通道的状态；仅由音频工作线程访问并拥有对应 BASS stream。
struct AudioChannel {
    DWORD stream{};
    float base_frequency{};
    float volume{1.0f};
    float speed{1.0f};
    double max_duration{};
    bool spatial{};
};

HINSTANCE g_module{};
std::atomic<bool> g_running{true};

std::vector<std::string> split_tabs(const std::string& value) {
    std::vector<std::string> parts;
    std::stringstream stream(value);
    std::string part;
    while (std::getline(stream, part, '\t')) parts.push_back(part);
    return parts;
}

std::string hex_encode(const std::string& value) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.reserve(value.size() * 2);
    for (unsigned char byte : value) { result.push_back(digits[byte >> 4]); result.push_back(digits[byte & 15]); }
    return result;
}

bool hex_decode(const std::string& value, std::string& result) {
    if ((value.size() & 1) != 0) return false;
    result.clear(); result.reserve(value.size() / 2);
    auto digit = [](char c) -> int { if (c >= '0' && c <= '9') return c - '0'; if (c >= 'a' && c <= 'f') return c - 'a' + 10; if (c >= 'A' && c <= 'F') return c - 'A' + 10; return -1; };
    for (std::size_t i = 0; i < value.size(); i += 2) { int hi = digit(value[i]), lo = digit(value[i + 1]); if (hi < 0 || lo < 0) return false; result.push_back(static_cast<char>((hi << 4) | lo)); }
    return true;
}

std::wstring utf8_to_wide(const std::string& value) {
    if (value.empty()) return {};
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (!size) {
        size = MultiByteToWideChar(CP_ACP, 0, value.data(),
            static_cast<int>(value.size()), nullptr, 0);
        if (!size) return {};
        std::wstring result(size, L'\0');
        MultiByteToWideChar(CP_ACP, 0, value.data(),
            static_cast<int>(value.size()), result.data(), size);
        return result;
    }
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), result.data(), size);
    return result;
}

std::string wide_to_utf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!size) return {};
    std::string result(size, '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
    return result;
}

float parse_float(const std::string& value) {
    try { return std::stof(value); }
    catch (...) { return 0.0f; }
}

bool parse_channel_id(const std::string& value, std::uint32_t& result) {
    try {
        std::size_t consumed = 0;
        const auto parsed = std::stoull(value, &consumed, 10);
        if (consumed != value.size() || parsed > UINT32_MAX) return false;
        result = static_cast<std::uint32_t>(parsed);
        return true;
    } catch (...) {
        return false;
    }
}

bool parse_vector(const std::vector<std::string>& parts, std::size_t index,
    BassVector& result) {
    if (parts.size() <= index + 2) return false;
    try {
        result = {std::stof(parts[index]), std::stof(parts[index + 1]),
            std::stof(parts[index + 2])};
        return true;
    } catch (...) {
        return false;
    }
}

float clamp(float value, float minimum, float maximum) {
    return std::max(minimum, std::min(maximum, value));
}

void write_text(const std::filesystem::path& path, const std::string& value) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (file) file << value;
}


bool write_text_atomic(const std::filesystem::path& path, const std::string& value) {
    const auto temporary = path.wstring() + L".tmp";
    {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (!file || !(file << value)) return false;
    }
    return MoveFileExW(temporary.c_str(), path.c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
}


void write_status(const std::filesystem::path& path, const char* state,
    const std::string& value) {
    write_text(path, std::string(state) + "\t" + value);
}

// 释放单个通道；必须在音频工作线程调用，避免跨线程访问 BASS。
void free_channel(BassApi& bass, AudioChannel& channel) {
    if (!channel.stream) return;
    bass.stop(channel.stream);
    bass.free_stream(channel.stream);
    channel = {};
}

bool is_safe_relative_path(const std::filesystem::path& path) {
    if (path.empty() || path.is_absolute()) return false;
    for (const auto& part : path) {
        if (part == L"..") return false;
    }
    return true;
}

// 通过固定 ASCII 请求文件提供 UTF-8 路径读写；实际文件操作始终使用宽字符 API。
bool utf8_write_file(const std::filesystem::path& data_dir, const std::string& path,
    const std::string& value, DWORD& error_code) {
    const auto relative = std::filesystem::path(utf8_to_wide(path)).lexically_normal();
    if (!is_safe_relative_path(relative)) { error_code = ERROR_INVALID_NAME; return false; }
    const auto full_path = data_dir / relative;
    HANDLE handle = CreateFileW(full_path.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        error_code = GetLastError();
        handle = CreateFileW(full_path.c_str(), GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    }
    if (handle == INVALID_HANDLE_VALUE) { error_code = GetLastError(); return false; }
    SetFilePointer(handle, 0, nullptr, FILE_BEGIN);
    SetEndOfFile(handle);
    DWORD written = 0;
    const bool ok = WriteFile(handle, value.data(), static_cast<DWORD>(value.size()), &written, nullptr)
        != FALSE && written == value.size();
    CloseHandle(handle);
    if (!ok) error_code = GetLastError();
    return ok;
}

std::string utf8_read_file(const std::filesystem::path& data_dir, const std::string& path,
    bool& ok) {
    const auto relative = std::filesystem::path(utf8_to_wide(path)).lexically_normal();
    if (!is_safe_relative_path(relative)) { ok = false; return {}; }
    std::ifstream file(data_dir / relative, std::ios::binary);
    if (!file) { ok = false; return {}; }
    ok = true;
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}

// 校验 Windows 单个目录段；允许 Unicode 与空格，拒绝设备名、控制字符和路径保留字符。
bool is_safe_group_directory_name(const std::wstring& name) {
    if (name.empty() || name == L"." || name == L".." ||
        name.back() == L'.' || name.back() == L' ') return false;
    constexpr std::wstring_view invalid = L"<>:\"/\\|?*";
    for (const auto character : name) {
        if (character < 32 || invalid.find(character) != std::wstring_view::npos)
            return false;
    }
    auto stem = name.substr(0, name.find(L'.'));
    std::transform(stem.begin(), stem.end(), stem.begin(), towlower);
    static const std::vector<std::wstring> reserved = {
        L"con", L"prn", L"aux", L"nul",
        L"com1", L"com2", L"com3", L"com4", L"com5",
        L"com6", L"com7", L"com8", L"com9",
        L"lpt1", L"lpt2", L"lpt3", L"lpt4", L"lpt5",
        L"lpt6", L"lpt7", L"lpt8", L"lpt9"
    };
    return std::find(reserved.begin(), reserved.end(), stem) == reserved.end();
}

// 仅允许 VoiceController/Groups/<安全目录名>/Audio；工作线程不会创建其他任意目录。
bool ensure_group_audio_directory(const std::filesystem::path& data_dir,
    const std::string& relative_name, std::string& error) {
    const auto relative_path = std::filesystem::path(
        utf8_to_wide(relative_name)).lexically_normal();
    if (!is_safe_relative_path(relative_path)) {
        error = "invalid_group_directory";
        return false;
    }
    std::vector<std::wstring> parts;
    for (const auto& part : relative_path) parts.push_back(part.wstring());
    if (parts.size() != 4 || _wcsicmp(parts[0].c_str(), L"VoiceController") != 0 ||
        _wcsicmp(parts[1].c_str(), L"Groups") != 0 ||
        _wcsicmp(parts[3].c_str(), L"Audio") != 0 ||
        !is_safe_group_directory_name(parts[2])) {
        error = "invalid_group_directory";
        return false;
    }
    std::error_code ec;
    std::filesystem::create_directories(data_dir / relative_path, ec);
    if (ec) {
        error = "create_group_directory_" + std::to_string(ec.value());
        return false;
    }
    return true;
}

// 使用 Windows 宽字符路径枚举外部音频，并输出严格 UTF-8 清单；只由音频工作线程调用。
void write_utf8_audio_catalog(const std::filesystem::path& data_dir,
    const std::filesystem::path& output_path) {
    const auto root = data_dir / L"VoiceController";
    std::vector<std::string> files;
    std::error_code ec;
    if (std::filesystem::is_directory(root, ec)) {
        auto iterator = std::filesystem::recursive_directory_iterator(root,
            std::filesystem::directory_options::skip_permission_denied, ec);
        const auto end = std::filesystem::recursive_directory_iterator{};
        while (!ec && iterator != end) {
            const auto& entry = *iterator;
            std::error_code entry_error;
            if (entry.is_regular_file(entry_error)) {
                auto extension = entry.path().extension().wstring();
                std::transform(extension.begin(), extension.end(), extension.begin(), towlower);
                if (extension == L".mp3" || extension == L".ogg" || extension == L".wav") {
                    const auto relative = entry.path().lexically_relative(data_dir);
                    auto path = wide_to_utf8(relative.wstring());
                    if (!path.empty() && path.find_first_of("\t\r\n") == std::string::npos)
                        files.push_back(std::move(path));
                }
            }
            iterator.increment(ec);
        }
    }
    std::sort(files.begin(), files.end());
    std::ostringstream output;
    output << "REFAudioCatalog\t1\n";
    for (const auto& file : files) output << file << '\n';
    output << "END\t" << files.size() << '\n';
    write_text_atomic(output_path, output.str());
}

// 在指定通道加载并立即播放文件；错误通过字符串返回，由工作线程统一写状态。
bool load_channel(BassApi& bass, const std::filesystem::path& data_dir,
    const std::string& relative_name, float volume, float speed,
    double max_duration, bool spatial, const BassVector* source_position,
    float min_distance, float max_distance, AudioChannel& channel,
    std::string& error) {
    free_channel(bass, channel);
    const auto relative_path = std::filesystem::path(
        utf8_to_wide(relative_name)).lexically_normal();
    if (!is_safe_relative_path(relative_path)) {
        error = "invalid_music_path";
        return false;
    }
    const auto path = data_dir / relative_path;
    const DWORD flags = BASS_UNICODE |
        (spatial ? (BASS_SAMPLE_3D | BASS_SAMPLE_MONO) : 0);
    channel.stream = bass.create_stream(FALSE, path.c_str(), 0, 0, flags);
    if (!channel.stream) {
        error = "bass_" + std::to_string(bass.error());
        return false;
    }
    if (!bass.get_attribute(channel.stream, BASS_ATTRIB_FREQ,
        &channel.base_frequency)) channel.base_frequency = 0.0f;
    channel.volume = clamp(volume, 0.0f, 1.0f);
    channel.speed = std::max(0.1f, speed);
    channel.max_duration = std::max(0.0, max_duration);
    channel.spatial = spatial;
    bass.set_attribute(channel.stream, BASS_ATTRIB_VOL, channel.volume);
    if (channel.base_frequency > 0.0f)
        bass.set_attribute(channel.stream, BASS_ATTRIB_FREQ,
            channel.base_frequency * channel.speed);
    if (spatial) {
        const float minimum = std::max(0.01f, min_distance);
        const float maximum = std::max(minimum, max_distance);
        if (!bass.set_3d_attributes(channel.stream, BASS_3DMODE_NORMAL,
            minimum, maximum, 360, 360, 0.0f) ||
            !bass.set_3d_position(channel.stream, source_position, nullptr, nullptr)) {
            error = "bass_3d_" + std::to_string(bass.error());
            free_channel(bass, channel);
            return false;
        }
        bass.apply_3d();
    }
    if (!bass.play(channel.stream, TRUE)) {
        error = "bass_" + std::to_string(bass.error());
        free_channel(bass, channel);
        return false;
    }
    return true;
}

// 输出全部通道的轻量状态快照；第一行之外不承担命令确认语义。
void write_channels_status(BassApi& bass,
    const std::map<std::uint32_t, AudioChannel>& channels,
    const std::filesystem::path& path) {
    std::ostringstream output;
    for (const auto& [id, channel] : channels) {
        const auto seconds = bass.bytes_to_seconds(channel.stream,
            bass.position(channel.stream, BASS_POS_BYTE));
        const DWORD active = bass.active(channel.stream);
        const char* state = active == BASS_ACTIVE_PLAYING ? "playing" :
            active == BASS_ACTIVE_PAUSED ? "paused" : "stopped";
        output << id << '\t' << state << '\t' << seconds << '\t'
            << channel.volume << '\t' << channel.speed << '\t'
            << channel.max_duration << '\t' << (channel.spatial ? "3d" : "2d") << '\n';
    }
    write_text(path, output.str());
}

void run_audio_worker() {
    HANDLE mutex = CreateMutexW(nullptr, TRUE, L"Local\\REFAudio");
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (mutex) CloseHandle(mutex);
        return;
    }

    wchar_t module_path[MAX_PATH]{};
    GetModuleFileNameW(g_module, module_path, MAX_PATH);
    const auto reframework_dir = std::filesystem::path(module_path).parent_path()
        .parent_path();
    const auto base_dir = reframework_dir / L"data" / L"REFAudio";
    const auto command_path = base_dir / L"audio_command.txt";
    const auto utf8_command_path = base_dir / L"audio_utf8_command.txt";
    const auto status_path = base_dir / L"audio_status.txt";
    const auto channels_path = base_dir / L"audio_channels.txt";
    const auto backend_path = base_dir / L"audio_backend.txt";
    const auto catalog_path = base_dir / L"audio_catalog_utf8.txt";
    const auto data_dir = base_dir.parent_path();

    // A command from an earlier game session must never auto-start music.
    DeleteFileW(command_path.c_str());
    DeleteFileW(utf8_command_path.c_str());
    write_text(backend_path,
        "REFAudio\t1\tmultichannel=1\tmax_channels=32\tgroup_dirs=1\tcatalog_utf8=1\tspatial3d=1");
    write_utf8_audio_catalog(data_dir, catalog_path);

    BassApi bass;
    if (!bass.load(base_dir / L"REFAudio_BASS.dll")) {
        write_status(status_path, "error", "bass_dll_load");
        CloseHandle(mutex);
        return;
    }
    if (!bass.init(-1, 44100, BASS_DEVICE_3D, nullptr, nullptr)) {
        write_status(status_path, "error", "bass_init_" +
            std::to_string(bass.error()));
        CloseHandle(mutex);
        return;
    }

    std::map<std::uint32_t, AudioChannel> channels;
    std::string last_command;
    auto next_catalog_scan = std::chrono::steady_clock::now() +
        std::chrono::seconds(10);
    write_status(status_path, "stopped", "0");

    while (g_running) {
        std::string utf8_command;
        { std::ifstream file(utf8_command_path, std::ios::binary); if (file) utf8_command.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()); }
        if (!utf8_command.empty()) {
            const auto parts = split_tabs(utf8_command);
            if (parts.size() >= 4 && (parts[2] == "utf8_read" || parts[2] == "utf8_write")) {
                std::string relative_path, payload;
                bool success = hex_decode(parts[3], relative_path);
                if (success && parts[2] == "utf8_write") success = parts.size() >= 5 && hex_decode(parts[4], payload);
                bool read_ok = false;
                if (success && parts[2] == "utf8_read") payload = utf8_read_file(data_dir, relative_path, read_ok), success = read_ok;
                DWORD io_error = ERROR_SUCCESS;
                if (success && parts[2] == "utf8_write") success = utf8_write_file(data_dir, relative_path, payload, io_error);
                const auto response_path = base_dir / (L"audio_utf8_response_" + utf8_to_wide(parts[1]) + L".txt");
                write_text_atomic(response_path, parts[1] + "\t" + (success ? "ok\t" : "error\t") + (success ? hex_encode(payload) : ("utf8_io_" + std::to_string(io_error))) + "\n");
            }
            DeleteFileW(utf8_command_path.c_str());
        }
        std::string command;
        {
            // 只在读取期间持有文件句柄，避免 20ms 轮询周期持续阻塞 Lua 覆写命令。
            std::ifstream command_file(command_path, std::ios::binary);
            if (command_file) {
                command.assign(std::istreambuf_iterator<char>(command_file),
                    std::istreambuf_iterator<char>());
            }
        }
        if (!command.empty() && command != last_command) {
            const auto parts = split_tabs(command);
            if (parts.size() >= 3 && !parts[0].empty()) {
                const auto& action = parts[2];
                std::uint32_t channel_id = 0;
                const bool is_load = action == "load" || action == "load3d";
                const bool channelized_load = is_load &&
                    parts.size() >= 7 && parse_channel_id(parts[3], channel_id);
                const bool command_has_value = action == "seek" ||
                    action == "volume" || action == "speed" ||
                    action == "max_duration" || action == "position3d";
                const bool channelized_command = !is_load &&
                    parts.size() >= (command_has_value ? 5u : 4u) &&
                    parse_channel_id(parts[3], channel_id);
                const bool channelized = channelized_load || channelized_command;
                const std::size_t value_index = channelized ? 4 : 3;

                if (action == "stop_all") {
                    for (auto& [_, channel] : channels) free_channel(bass, channel);
                    channels.clear();
                } else if (action == "ensure_dir") {
                    if (parts.size() >= 5) {
                        std::string error;
                        if (!ensure_group_audio_directory(data_dir, parts[4], error))
                            write_status(status_path, "error", error);
                    }
                } else if (is_load) {
                    const std::size_t path_index = channelized ? 4 : 3;
                    if ((!channelized && parts.size() >= 6) || channelized_load) {
                        const bool new_channel = channels.find(channel_id) == channels.end();
                        if (new_channel && channels.size() >= MAX_CHANNELS) {
                            write_status(status_path, "error", "channel_limit");
                        } else {
                            auto& channel = channels[channel_id];
                            std::string error;
                            const double max_duration = parts.size() > path_index + 3 ?
                                parse_float(parts[path_index + 3]) : 0.0;
                            const bool spatial = action == "load3d";
                            BassVector source{}, listener{}, front{}, top{};
                            const std::size_t spatial_index = path_index + 4;
                            const bool spatial_values = !spatial ||
                                (parse_vector(parts, spatial_index, source) &&
                                parts.size() > spatial_index + 4 &&
                                parse_vector(parts, spatial_index + 5, listener) &&
                                parse_vector(parts, spatial_index + 8, front) &&
                                parse_vector(parts, spatial_index + 11, top));
                            if (!spatial_values) {
                                write_status(status_path, "error", "invalid_3d_values");
                                channels.erase(channel_id);
                                last_command = command;
                                continue;
                            }
                            if (spatial) {
                                bass.set_listener_3d_position(&listener, nullptr, &front, &top);
                            }
                            if (!load_channel(bass, data_dir, parts[path_index],
                                parse_float(parts[path_index + 1]),
                                parse_float(parts[path_index + 2]), max_duration,
                                spatial, spatial ? &source : nullptr,
                                spatial ? parse_float(parts[spatial_index + 3]) : 1.0f,
                                spatial ? parse_float(parts[spatial_index + 4]) : 10000.0f,
                                channel, error)) {
                                channels.erase(channel_id);
                                write_status(status_path, "error", error);
                            }
                        }
                    }
                } else {
                    auto found = channels.find(channel_id);
                    if (found != channels.end()) {
                        auto& channel = found->second;
                        if (action == "pause") {
                            bass.pause(channel.stream);
                        } else if (action == "resume" || action == "play") {
                            bass.play(channel.stream, FALSE);
                        } else if (action == "stop") {
                            free_channel(bass, channel);
                            channels.erase(found);
                        } else if (action == "restart") {
                            bass.play(channel.stream, TRUE);
                        } else if (action == "seek" && parts.size() > value_index) {
                            bass.set_position(channel.stream,
                                bass.seconds_to_bytes(channel.stream,
                                    std::max(0.0f, parse_float(parts[value_index]))),
                                BASS_POS_BYTE);
                        } else if (action == "volume" && parts.size() > value_index) {
                            channel.volume = clamp(parse_float(parts[value_index]), 0.0f, 1.0f);
                            bass.set_attribute(channel.stream, BASS_ATTRIB_VOL, channel.volume);
                        } else if (action == "speed" && parts.size() > value_index) {
                            channel.speed = std::max(0.1f, parse_float(parts[value_index]));
                            if (channel.base_frequency > 0.0f)
                                bass.set_attribute(channel.stream, BASS_ATTRIB_FREQ,
                                    channel.base_frequency * channel.speed);
                        } else if (action == "max_duration" && parts.size() > value_index) {
                            channel.max_duration = std::max(0.0f,
                                parse_float(parts[value_index]));
                        } else if (action == "position3d" && channel.spatial) {
                            BassVector source{}, listener{}, front{}, top{};
                            if (parse_vector(parts, value_index, source) &&
                                parse_vector(parts, value_index + 3, listener) &&
                                parse_vector(parts, value_index + 6, front) &&
                                parse_vector(parts, value_index + 9, top)) {
                                bass.set_3d_position(channel.stream, &source, nullptr, nullptr);
                                bass.set_listener_3d_position(&listener, nullptr, &front, &top);
                                bass.apply_3d();
                            }
                        }
                    }
                }
                last_command = command;
            }
        }

        for (auto it = channels.begin(); it != channels.end();) {
            auto& channel = it->second;
            const auto seconds = bass.bytes_to_seconds(channel.stream,
                bass.position(channel.stream, BASS_POS_BYTE));
            const bool duration_reached = channel.max_duration > 0.0 &&
                seconds >= channel.max_duration;
            if (duration_reached || bass.active(channel.stream) == 0) {
                free_channel(bass, channel);
                it = channels.erase(it);
            } else {
                ++it;
            }
        }

        const auto legacy = channels.find(0);
        if (legacy == channels.end()) {
            write_status(status_path, "stopped", "0");
        } else {
            const auto seconds = bass.bytes_to_seconds(legacy->second.stream,
                bass.position(legacy->second.stream, BASS_POS_BYTE));
            const DWORD active = bass.active(legacy->second.stream);
            const char* state = active == BASS_ACTIVE_PLAYING ? "playing" :
                active == BASS_ACTIVE_PAUSED ? "paused" : "stopped";
            write_status(status_path, state, std::to_string(seconds));
        }
        write_channels_status(bass, channels, channels_path);
        const auto current_time = std::chrono::steady_clock::now();
        if (current_time >= next_catalog_scan) {
            write_utf8_audio_catalog(data_dir, catalog_path);
            next_catalog_scan = current_time + std::chrono::seconds(10);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }

    for (auto& [_, channel] : channels) free_channel(bass, channel);
    channels.clear();
    bass.free();
    write_status(status_path, "stopped", "0");
    CloseHandle(mutex);
}

DWORD WINAPI worker_entry(void*) {
    run_audio_worker();
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = module;
        DisableThreadLibraryCalls(module);
        HANDLE thread = CreateThread(nullptr, 0, worker_entry, nullptr, 0, nullptr);
        if (thread) CloseHandle(thread);
    } else if (reason == DLL_PROCESS_DETACH) {
        g_running = false;
    }
    return TRUE;
}
