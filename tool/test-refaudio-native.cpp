// 独立原生验收：使用真实 BASS 和临时邮箱，不连接游戏或读取用户配置。
#include "../native/REFAudio.cpp"
#include <iostream>
#include <stdexcept>
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
int main() {
    try {
    auto root = std::filesystem::temp_directory_path() / (L"refaudio-test-" + std::to_wstring(GetCurrentProcessId()));
    std::filesystem::create_directories(root / L"REFAudio/clients/deepseekcat");
    std::filesystem::create_directories(root / L"REFAudio/clients/other");
    BassApi bass;
    check(bass.load(L"reframework/data/REFAudio/REFAudio_BASS.dll"), "bass load");
    check(bass.init(-1, 44100, BASS_DEVICE_3D, nullptr, nullptr), "bass init");
    // 6 声道 PCM WAV，所有输入声道都应参与平均混合。
    std::vector<unsigned char> wave(44 + 4410 * 6 * 2, 0);
    auto put = [&](int at, DWORD v, int n) { for (int i = 0; i < n; ++i) wave[at + i] = static_cast<unsigned char>(v >> (8 * i)); };
    memcpy(wave.data(), "RIFF", 4); put(4, wave.size()-8, 4); memcpy(wave.data()+8,"WAVEfmt ",8);
    put(16,16,4);put(20,1,2);put(22,6,2);put(24,44100,4);put(28,44100*12,4);put(32,12,2);put(34,16,2);
    memcpy(wave.data()+36,"data",4);put(40,wave.size()-44,4);
    for (int frame = 0; frame < 4410; ++frame) for (int c = 0; c < 6; ++c) put(44 + (frame * 6 + c) * 2, 1000 * (c + 1), 2);
    std::ofstream(root / L"six.wav",std::ios::binary).write(reinterpret_cast<char*>(wave.data()),wave.size());
    AudioChannel spatial; BassVector position{0,0,1};std::string error;
    check(load_channel(bass,root,"six.wav",1,1,0,true,&position,1,100,spatial,error), error.c_str());
    BassChannelInfo info{};check(bass.info(spatial.stream,&info) && info.chans == 1,"mono output");check(spatial.mono_wave && (*spatial.mono_wave)[44] == (3500 & 255) && (*spatial.mono_wave)[45] == (3500 >> 8),"mixed sample amplitude");free_channel(bass,spatial);
    auto mp3 = std::filesystem::temp_directory_path() / L"refaudio-stereo-test.mp3";
    if (std::filesystem::exists(mp3)) {
        std::filesystem::copy_file(mp3, root / L"stereo.mp3", std::filesystem::copy_options::overwrite_existing);
        check(load_channel(bass,root,"stereo.mp3",1,1,0,true,&position,1,100,spatial,error),"stereo MP3 3D");
        check(bass.info(spatial.stream,&info) && info.chans == 1,"MP3 downmix"); free_channel(bass,spatial);
        check(load_channel(bass,root,"stereo.mp3",1,1,0,false,nullptr,1,100,spatial,error),"MP3 2D");
        check(bass.info(spatial.stream,&info) && info.chans == 2,"2D preserves stereo"); free_channel(bass,spatial);
    }
    std::filesystem::create_directories(root / L"VoiceController/Groups/测试/Audio");
    DWORD io_error{}; bool io_ok{};
    check(utf8_write_file(root,"VoiceController/Groups/测试/group.json","{\"name\":\"测试\"}",io_error),"UTF8 bridge write");
    check(utf8_read_file(root,"VoiceController/Groups/测试/group.json",io_ok)=="{\"name\":\"测试\"}" && io_ok,"UTF8 bridge read");
    std::map<std::string,MailboxClient> clients;
    auto base=root/L"REFAudio";auto dir=base/L"clients/deepseekcat";
    // 声卡输出缓冲和调度时间不确定；以真实状态为准，在有界超时内轮询。
    auto wait_until=[&](const auto& predicate){
        auto deadline=GetTickCount64()+4000;
        do {poll_mailboxes(bass,base,root,"boot",clients,0);if(predicate())return true;Sleep(20);}while(GetTickCount64()<deadline);
        return false;
    };
    auto submit=[&](const std::string& name,const std::string& body) {
        write_text_atomic(base/L"clients"/utf8_to_wide(name)/L"command.txt",body);
        poll_mailboxes(bass,base,root,"boot",clients,0);
        std::ifstream f(base/L"clients"/utf8_to_wide(name)/L"response.txt",std::ios::binary);
        return std::string(std::istreambuf_iterator<char>(f),{});
    };
    check(submit("deepseekcat","boot\tsession\t1\tload\t7\tsix.wav\t1\t1\t0").find("\tok\t")!=std::string::npos,"first load");
    auto first=clients["deepseekcat"].channels[7].stream;
    check(submit("other","boot\tsession\t1\tload\t7\tsix.wav\t1\t1\t0").find("\tok\t")!=std::string::npos,"second load");
    check(clients["other"].channels[7].stream != first,"channel ownership");
    check(submit("deepseekcat","boot\tsession\t1\tload\t7\tsix.wav\t1\t1\t0").find("\tok\t")!=std::string::npos && clients["deepseekcat"].channels[7].stream==first,"dedupe");
    check(submit("deepseekcat","boot\tsession\t1\tstop\t7").find("request_conflict")!=std::string::npos,"conflicting id");
    check(submit("deepseekcat","old\tsession\t2\tstop\t7").find("boot_mismatch")!=std::string::npos,"old boot");
    check(submit("deepseekcat","boot\tsession\t2\tstop\t7").find("\tok\t")!=std::string::npos && clients["other"].channels.count(7),"isolated stop");
    check(submit("deepseekcat","boot\tsession\t3\tload\t7\tmissing.mp3\t1\t1\t0").find("file_not_found")!=std::string::npos,"missing file");
    check(submit("deepseekcat","boot\tsession\t4\tload\t7\tsix.wav\tnan\t1\t0").find("invalid_parameter")!=std::string::npos,"nan rejection");
    check(submit("deepseekcat","boot\tsession\t5\tload\t7\t../six.wav\t1\t1\t0").find("invalid_path")!=std::string::npos,"traversal");
    check(submit("deepseekcat","boot\tsession\t6\tload\t7\tsix.wav\t1\t1\t0").find("\tok\t")!=std::string::npos,"reload");
    write_text_atomic(dir / L"command.txt", "boot\tsession\t7\tload\t8\tsix.wav\t1\t1\t0");
    poll_mailboxes(bass,base,root,"boot",clients,32);
    check(!clients["deepseekcat"].channels.count(8),"shared channel limit");
    auto spatial_load = submit("deepseekcat", "boot\tsession\t8\tload3d\t7\tsix.wav\t1\t1\t0\t0\t0\t1\t1\t40\t0\t0\t0\t0\t0\t1\t0\t1\t0");
    check(spatial_load.find("\tok\t")!=std::string::npos && clients["deepseekcat"].channels[7].spatial,
        "isolated 3D load");
    auto source_stream=clients["deepseekcat"].channels[7].stream;
    auto spatial_update = submit("deepseekcat", "boot\tsession\t9\tposition3d\t7\t0\t0\t2\t0\t0\t0\t0\t0\t1\t0\t1\t0");
    check(spatial_update.find("\tok\t")!=std::string::npos,"isolated 3D position update");
    using Get3DPosition=BOOL(WINAPI*)(DWORD,BassVector*,BassVector*,BassVector*);
    auto get_3d_position=reinterpret_cast<Get3DPosition>(GetProcAddress(bass.module,"BASS_ChannelGet3DPosition"));
    BassVector actual{};
    check(get_3d_position&&get_3d_position(source_stream,&actual,nullptr,nullptr)&&actual.z==2,
        "position command actually updates the BASS source");
    check(clients["deepseekcat"].channels[7].stream==source_stream,"position update never reloads stream");
    auto gain_update = submit("deepseekcat", "boot\tsession\t10\tposition3d\t7\t0\t0\t2\t0\t0\t0\t0\t0\t1\t0\t1\t0\t0.6");
    check(gain_update.find("\tok\t")!=std::string::npos && clients["deepseekcat"].channels[7].volume==0.6f,
        "position update applies explicit distance-floor gain");
    float actual_gain{};
    check(bass.get_attribute(source_stream,BASS_ATTRIB_VOL,&actual_gain)&&std::abs(actual_gain-.6f)<.001f,
        "distance-floor gain reaches the live BASS stream");
    check(submit("deepseekcat", "boot\tsession\t11\tposition3d\t7\tnan\t0\t2\t0\t0\t0\t0\t0\t1\t0\t1\t0").find("invalid_parameter")!=std::string::npos,
        "3D rejects NaN coordinates");
    check(submit("deepseekcat", "boot\tsession\t12\tposition3d\t7\t0\t0\t2\t0\t0\t0\t0\t0\t1\t0\t1\t0\t5.1").find("invalid_parameter")!=std::string::npos,
        "3D rejects out-of-range dynamic gain");
    check(submit("deepseekcat", "boot\tsession\t13\tposition3d\t7\t0\t0\t2\t0\t0\t0\t0\t0\t0\t0\t1\t0").find("invalid_parameter")!=std::string::npos,
        "3D rejects zero direction");
    check(submit("deepseekcat", "boot\tsession\t14\tposition3d\t7\t0\t0\t2\t0\t0\t0\t0\t0\t1\t0\t1\t0\tnan").find("invalid_parameter")!=std::string::npos,
        "3D rejects NaN dynamic gain");
    check(bass.get_attribute(source_stream,BASS_ATTRIB_VOL,&actual_gain)&&std::abs(actual_gain-.6f)<.001f,
        "invalid updates leave current playback gain unchanged");
    check(submit("deepseekcat", "boot\tsession\t15\tposition3d\t7\t0\t0\t1\t0\t0\t0\t0\t0\t1\t0\t1\t0\t0").find("\tok\t")!=std::string::npos &&
        bass.get_attribute(source_stream,BASS_ATTRIB_VOL,&actual_gain)&&actual_gain==0,
        "dynamic gain zero keeps explicit silence");
    check(submit("deepseekcat", "boot\tsession\t16\tposition3d\t7\t0\t0\t1\t0\t0\t0\t0\t0\t1\t0\t1\t0").find("\tok\t")!=std::string::npos &&
        bass.get_attribute(source_stream,BASS_ATTRIB_VOL,&actual_gain)&&actual_gain==0,
        "legacy position updates preserve gain");
    check(submit("deepseekcat", "boot\tsession\t17\tposition3d\t7\t0\t0\t1\t0\t0\t0\t0\t0\t1\t0\t1\t0\t5").find("\tok\t")!=std::string::npos &&
        bass.get_attribute(source_stream,BASS_ATTRIB_VOL,&actual_gain)&&std::abs(actual_gain-5.f)<.001f && clients["deepseekcat"].channels[7].stream==source_stream,
        "dynamic gain restores maximum volume without reloading");
    check(submit("deepseekcat", "boot\tsession\t18\tstop_client\t0").find("\tok\t")!=std::string::npos,
        "3D client stop");
    check(submit("deepseekcat", "boot\tsession\t19\tload3d\t7\tsix.wav\t1\t1\t0\t0\t0\t1\t1\t40\t0\t0\t0\t0\t0\t1\t0\t1\t0").find("\tok\t")!=std::string::npos,"3D reload before natural end");
    check(wait_until([&](){return clients["deepseekcat"].states[7]=="ended";}),"natural end");
    check(submit("deepseekcat", "boot\tsession\t20\tposition3d\t7\t0\t0\t2\t0\t0\t0\t0\t0\t1\t0\t1\t0\t0.6").find("\tok\t")!=std::string::npos && clients["deepseekcat"].states[7]=="ended","position at natural end is harmless");

    // PCM 真实 BASS 回归：短于预缓冲的音频经 finish 正常启动、EOF 排空，旧请求不自动重播。
    auto stream_dir=base/L"clients"/L"deepseekcat";
    auto stream_start=[&](const char* id){write_text_atomic(stream_dir/L"stream_command.json", "");
        write_text_atomic(stream_dir/L"stream_start.json",std::string("{\"boot_id\":\"boot\",\"session_id\":\"pcm-session\",\"request_id\":\"")+id+
            "\",\"local_channel\":0,\"format\":\"pcm_s16le\",\"sample_rate\":32000,\"channels\":1,\"bits_per_sample\":16,\"volume\":2,\"speed\":1,\"max_duration_seconds\":60,\"prebuffer_ms\":160,\"stream_directory\":\"DeepSeekCat/tts-stream/test\"}");
        poll_mailboxes(bass,base,root,"boot",clients,0);};
    auto stream_command=[&](const char* id,int command,const std::string& fields){
        write_text_atomic(stream_dir/L"stream_command.json",std::string("{\"boot_id\":\"boot\",\"session_id\":\"pcm-session\",\"request_id\":\"")+id+"\",\"command_id\":"+std::to_string(command)+","+fields+"}");
        poll_mailboxes(bass,base,root,"boot",clients,0);};
    stream_start("short-pcm");check(clients["deepseekcat"].stream&&clients["deepseekcat"].stream->state=="buffering","PCM push stream created");
    std::vector<unsigned char> short_pcm(6400,0);std::ofstream(root/L"short.bin",std::ios::binary).write(reinterpret_cast<char*>(short_pcm.data()),short_pcm.size());
    stream_command("short-pcm",1,"\"action\":\"start\"");
    stream_command("short-pcm",2,"\"action\":\"chunk\",\"chunk_index\":1,\"file\":\"short.bin\",\"bytes\":6400");
    check(clients["deepseekcat"].stream->received_bytes==6400&&!clients["deepseekcat"].stream->started,"short PCM waits for prebuffer");
    poll_mailboxes(bass,base,root,"boot",clients,0);
    check(clients["deepseekcat"].stream->received_bytes==6400&&clients["deepseekcat"].stream->state=="buffering","duplicate chunk is not consumed again");
    stream_command("short-pcm",3,"\"action\":\"finish\"");
    check(clients["deepseekcat"].stream&&clients["deepseekcat"].stream->state=="draining","finish plays short stream");
    Sleep(400);poll_mailboxes(bass,base,root,"boot",clients,0);
    check(!clients["deepseekcat"].stream,"PCM EOF ends and frees stream");
    poll_mailboxes(bass,base,root,"boot",clients,0);check(!clients["deepseekcat"].stream,"ended start file never replays");
    stream_start("next-pcm");stream_command("next-pcm",4,"\"action\":\"stop\"");check(!clients["deepseekcat"].stream,"next PCM stream can start and stop independently");
    // 真实 BASS 断流回归：耗尽后只计一次，细碎来包不能反复起播，finish 允许不足阈值的尾段续播。
    std::vector<unsigned char> block(12800,0);std::ofstream(root/L"block.bin",std::ios::binary).write(reinterpret_cast<char*>(block.data()),block.size());
    auto pcm_chunk=[&](const char* id,int command,int index){stream_command(id,command,"\"action\":\"chunk\",\"chunk_index\":"+std::to_string(index)+",\"file\":\"block.bin\",\"bytes\":12800");};
    stream_start("gap-pcm");stream_command("gap-pcm",1,"\"action\":\"start\"");pcm_chunk("gap-pcm",2,1);
    Sleep(700);poll_mailboxes(bass,base,root,"boot",clients,0);
    if(!clients["deepseekcat"].stream){std::ifstream f(stream_dir/L"stream_state.json");std::cerr<<std::string(std::istreambuf_iterator<char>(f),{})<<std::endl;throw std::runtime_error("gap stream disappeared before recovery");}
    auto& gap=*clients["deepseekcat"].stream;
    check(gap.rebuffering&&gap.state=="buffering"&&gap.underrun_count==1,"real exhausted push stream is tracked and paused for rebuffer");
    pcm_chunk("gap-pcm",3,2);Sleep(80);poll_mailboxes(bass,base,root,"boot",clients,0);
    check(gap.rebuffering&&gap.underrun_count==1,"200ms tiny refill cannot restart stalled playback");
    pcm_chunk("gap-pcm",4,3);check(gap.rebuffering,"400ms refill still waits for stable buffer");
    pcm_chunk("gap-pcm",5,4);check(!gap.rebuffering&&gap.state=="playing"&&gap.rebuffer_ms>0,"600ms refill resumes without reset");
    Sleep(1000);poll_mailboxes(bass,base,root,"boot",clients,0);check(gap.rebuffering&&gap.underrun_count==2,"separate gap counted once");
    pcm_chunk("gap-pcm",6,5);stream_command("gap-pcm",7,"\"action\":\"finish\"");
    check(!gap.rebuffering&&gap.state=="draining","finish resumes short tail below refill threshold");
    Sleep(500);poll_mailboxes(bass,base,root,"boot",clients,0);check(!clients["deepseekcat"].stream,"recovered stream drains to EOF");
    {std::ifstream f(stream_dir/L"stream_state.json");std::string body(std::istreambuf_iterator<char>(f),{});
        check(body.find("\"underrun_count\":2")!=std::string::npos&&body.find("\"consumed_bytes\":64000")!=std::string::npos,"terminal diagnosis retains two gaps and every PCM byte");}
    // 正常速率供给：细碎分片整体先于播放到达，不应误判断流。
    stream_start("steady-pcm");stream_command("steady-pcm",1,"\"action\":\"start\"");
    for(int i=1;i<=10;i++){pcm_chunk("steady-pcm",i+1,i);Sleep(30);poll_mailboxes(bass,base,root,"boot",clients,0);}
    check(clients["deepseekcat"].stream->underrun_count==0,"healthy ongoing producer never underruns");
    stream_command("steady-pcm",12,"\"action\":\"finish\"");Sleep(2300);poll_mailboxes(bass,base,root,"boot",clients,0);
    check(!clients["deepseekcat"].stream,"healthy continuous audio ends without stream leakage");
    // 流式 3D 真实 BASS 验收：纯 PCM 客户端不创建 command.txt，位置快照不占用命令确认。
    auto three_dir=base/L"clients"/L"stream3d";std::filesystem::create_directories(three_dir);
    auto read_file=[&](const std::filesystem::path& p){std::ifstream f(p,std::ios::binary);return std::string(std::istreambuf_iterator<char>(f),{});};
    auto tick=[&](){poll_mailboxes(bass,base,root,"boot",clients,0);};
    auto make_start=[&](const std::string& id,const std::string& extra="",int chans=1){return std::string(
        "{\"boot_id\":\"boot\",\"session_id\":\"three\",\"request_id\":\"")+id+
        "\",\"local_channel\":0,\"format\":\"pcm_s16le\",\"sample_rate\":32000,\"channels\":"+std::to_string(chans)+
        ",\"bits_per_sample\":16,\"volume\":2,\"speed\":1,\"max_duration_seconds\":60,\"prebuffer_ms\":500,"+
        "\"stream_directory\":\"DeepSeekCat/tts-stream/test\",\"spatial\":true,\"source\":[0,0,1],\"listener\":[0,0,0],"+
        "\"front\":[0,0,2],\"top\":[0,2,0],\"reference_distance\":1.5,\"max_distance\":40"+extra+"}";};
    auto three_start=[&](const std::string& body){write_text_atomic(three_dir/L"stream_start.json",body);tick();};
    three_start(make_start("stereo", "", 2));check(!clients["stream3d"].stream&&read_file(three_dir/L"stream_response.json").find("spatial_requires_mono")!=std::string::npos,"reject stereo 3D PCM");
    auto missing=make_start("missing");auto offset=missing.find("\"source\":[0,0,1],");missing.erase(offset,std::strlen("\"source\":[0,0,1],"));
    three_start(missing);check(!clients["stream3d"].stream,"missing source never defaults to zero");
    three_start(make_start("duplicate"," ,\"volume\":1"));check(!clients["stream3d"].stream,"duplicate JSON keys rejected");
    three_start(make_start("cut").substr(0,make_start("cut").size()-1));check(!clients["stream3d"].stream,"half-written start rejected");
    three_start(make_start("three-main"));check(clients["stream3d"].stream!=nullptr,"pure PCM client discovered without legacy command file");
    auto& three=*clients["stream3d"].stream;auto handle=three.channel.stream;
    check(three.spatial&&bass.info(handle,&info)&&(info.flags&BASS_SAMPLE_3D)&&info.chans==1,"real push stream has BASS 3D flag and mono output");
    check(three.front.z==1&&three.top.y==1,"initial listener basis normalized");
    auto snapshot=[&](const std::string& id,int revision,const std::string& volume,const std::string& source="[1,0,0]",
        const std::string& front="[0,0,2]",const std::string& top="[0,3,0]",const std::string& boot="boot",const std::string& session="three") {
        return "{\"boot_id\":\""+boot+"\",\"session_id\":\""+session+"\",\"request_id\":\""+id+"\",\"revision\":"+
            std::to_string(revision)+",\"source\":"+source+",\"listener\":[0,0,0],\"front\":"+front+",\"top\":"+top+",\"volume\":"+volume+"}";};
    auto space=[&](const std::string& body){write_text_atomic(three_dir/L"stream_spatial.json",body);tick();return read_file(three_dir/L"stream_spatial_state.json");};
    auto cmd=[&](int id,const std::string& fields,const std::string& request="three-main") {
        write_text_atomic(three_dir/L"stream_command.json","{\"boot_id\":\"boot\",\"session_id\":\"three\",\"request_id\":\""+request+
            "\",\"command_id\":"+std::to_string(id)+","+fields+"}");tick();return read_file(three_dir/L"stream_response.json");};
    auto chunk3=[&](int command,int index,const std::string& request="three-main",const std::string& file="block.bin",int bytes=12800) {
        return cmd(command,"\"action\":\"chunk\",\"chunk_index\":"+std::to_string(index)+",\"file\":\""+file+"\",\"bytes\":"+std::to_string(bytes),request);};
    check(space(snapshot("three-main",1,"0")).find("\"status\":\"ok\"")!=std::string::npos&&three.state=="buffering"&&!three.started,"buffering snapshot never starts playback");
    check(bass.get_attribute(handle,BASS_ATTRIB_VOL,&actual_gain)&&actual_gain==0,"buffering gain is really muted");
    check(get_3d_position(handle,&actual,nullptr,nullptr)&&actual.x==1,"snapshot reaches BASS position");
    const auto accepted_snapshot=read_file(three_dir/L"stream_spatial.json");
    check(space(snapshot("three-main",1,"5")).find("revision_conflict")!=std::string::npos&&three.channel.volume==0,"same revision conflicting body rejected");
    check(space(accepted_snapshot).find("\"status\":\"ok\"")!=std::string::npos&&three.spatial_revision==1,"identical revision is harmless after conflict");
    for(const auto& bad:std::vector<std::string>{"NaN","Infinity","-1","5.1","1e309"}) {
        space(snapshot("three-main",2,bad));check(three.channel.volume==0&&three.spatial_revision==1,"invalid dynamic gain leaves previous value");
    }
    for(const auto& bad:std::vector<std::string>{snapshot("three-main",2,"1","[0,0]"),snapshot("three-main",2,"1","[NaN,0,0]"),
        snapshot("three-main",2,"1","[0,0,1]","[0,0,0]"),snapshot("three-main",2,"1","[0,0,1]","[0,1,0]","[0,2,0]"),
        snapshot("three-main",2,"1","[0,0,1]","[0,0,1]","[0,1,0]","old"),
        snapshot("old-request",2,"1"),snapshot("three-main",2,"1","[0,0,1]","[0,0,1]","[0,1,0]","boot","old-session"),
        snapshot("three-main",2,"1").substr(0,50)}) {
        space(bad);check(three.spatial_revision==1&&three.channel.volume==0&&get_3d_position(handle,&actual,nullptr,nullptr)&&actual.x==1,"invalid snapshot cannot partially mutate source/gain");
    }
    cmd(1,"\"action\":\"start\"");chunk3(2,1);chunk3(3,2);
    check(!three.started,"3D waits for 500ms initial prebuffer");chunk3(4,3);
    check(three.started&&three.state=="playing"&&bass.get_attribute(handle,BASS_ATTRIB_VOL,&actual_gain)&&actual_gain==0,"first play preserves latest muted gain");
    auto prior_position=bass.position(handle,BASS_POS_BYTE);auto received=three.received_bytes;auto command_before=three.command_id;
    for(int revision=5;revision<=8;revision++) {
        std::string gain=revision==5?"1":revision==6?"2":revision==7?"5":"0.6";
        space(snapshot("three-main",revision,gain,"[-1,0,0]","[1,0,0]"));
        check(three.channel.stream==handle&&bass.position(handle,BASS_POS_BYTE)>=prior_position&&three.received_bytes==received&&three.command_id==command_before&&three.next_chunk==3,"position does not reload seek or consume PCM commands/bytes");
        check(bass.get_attribute(handle,BASS_ATTRIB_VOL,&actual_gain)&&std::abs(actual_gain-std::stof(gain))<.001f,"dynamic gain reaches live BASS stream");
        prior_position=bass.position(handle,BASS_POS_BYTE);
    }
    check(space(snapshot("three-main",6,"0")).find("stale_revision")!=std::string::npos&&three.channel.volume==.6f,"old revision ignored");
    check(cmd(4,"\"action\":\"stop\"").find("request_conflict")!=std::string::npos&&three.state=="playing","command conflict cannot stop PCM");
    check(cmd(2,"\"action\":\"stop\"").find("stale_request")!=std::string::npos&&three.command_id==4,"stale command cannot rewind command ID");
    check(chunk3(4,3).find("\"status\":\"ok\"")!=std::string::npos&&three.received_bytes==received,"retry returns original ACK without duplicate chunk");
    Sleep(900);tick();check(three.rebuffering&&three.underrun_count==1,"3D first real underrun pauses for rebuffer");
    space(snapshot("three-main",9,"0"));check(three.rebuffering&&three.state=="buffering"&&three.channel.stream==handle,"position/gain during rebuffer never resumes");
    chunk3(5,4);chunk3(6,5);check(three.rebuffering,"400ms 3D refill still waits");chunk3(7,6);
    check(!three.rebuffering&&bass.get_attribute(handle,BASS_ATTRIB_VOL,&actual_gain)&&actual_gain==0,"500ms-plus refill resumes at new gain");
    Sleep(900);tick();check(three.rebuffering&&three.underrun_count==2,"3D second underrun retained");
    chunk3(8,7);space(snapshot("three-main",10,"2"));cmd(9,"\"action\":\"finish\"");
    check(three.state=="draining"&&!three.rebuffering,"3D finish resumes short tail");
    auto draining_bytes=three.received_bytes;space(snapshot("three-main",11,"1","[0,0,-1]"));
    check(three.channel.stream==handle&&three.state=="draining"&&three.received_bytes==draining_bytes,"draining remains spatial without new chunks");
    Sleep(500);tick();check(!clients["stream3d"].stream,"3D drains and releases stream");
    auto ended=read_file(three_dir/L"stream_state.json");
    check(ended.find("\"underrun_count\":2")!=std::string::npos&&ended.find("\"consumed_bytes\":89600")!=std::string::npos&&ended.find("\"spatial_revision\":11")!=std::string::npos,"3D final state preserves bytes gaps and revision");
    check(space(snapshot("three-main",12,"5")).find("\"status\":\"inactive\"")!=std::string::npos&&!clients["stream3d"].stream,"late position after EOF cannot restart");
    three_start(make_start("three-main")+" ");check(!clients["stream3d"].stream,"terminal request cannot replay with reformatted start");
    // 105 个细碎 PCM 分片与位置同时提交，音频 ACK、块序号和另一客户端句柄保持独立。
    std::vector<unsigned char> tiny(640,0);std::ofstream(root/L"tiny.bin",std::ios::binary).write(reinterpret_cast<char*>(tiny.data()),tiny.size());
    three_start(make_start("many"));
    auto many_handle=clients["stream3d"].stream->channel.stream;
    auto other_dir=base/L"clients"/L"pcm-other";std::filesystem::create_directories(other_dir);
    write_text_atomic(other_dir/L"stream_start.json",make_start("other"));tick();
    auto other_handle=clients["pcm-other"].stream->channel.stream;
    auto file_handle=clients["other"].channels[7].stream;
    for(int i=1;i<=105;i++) {
        write_text_atomic(three_dir/L"stream_spatial.json",snapshot("many",i,i%2?"0":"2"));
        check(chunk3(i,i,"many","tiny.bin",640).find("\"status\":\"ok\"")!=std::string::npos,"fine chunks ACK while independent position arrives");
        if(i%10==0){Sleep(30);tick();}
        check(clients["stream3d"].stream->channel.stream==many_handle&&clients["stream3d"].stream->received_bytes==static_cast<std::size_t>(i*640),"no missing or duplicate tiny PCM bytes");
    }
    auto& many=*clients["stream3d"].stream;
    check(many.spatial_revision==105&&many.received_chunks==105&&many.underrun_count==0,"105 revisions do not consume chunk command sequence");
    cmd(106,"\"action\":\"stop\"","many");check(!clients["stream3d"].stream&&clients["pcm-other"].stream->channel.stream==other_handle&&clients["other"].channels[7].stream==file_handle,"PCM stop only owns its stream");
    check(space(snapshot("many",106,"5")).find("\"status\":\"inactive\"")!=std::string::npos,"stop followed by position stays inactive");
    check(submit("pcm-other","boot\tfile-session\t1\tstop_client\t0").find("\tok\t")!=std::string::npos&&!clients["pcm-other"].stream,"stop_client also releases owned PCM");
    // 3D 首段短于预缓冲，finish 仍真正起播；错误快照不覆盖静音。
    three_start(make_start("short3d"));space(snapshot("short3d",1,"0"));chunk3(1,1,"short3d","short.bin",6400);
    cmd(2,"\"action\":\"finish\"","short3d");check(clients["stream3d"].stream&&clients["stream3d"].stream->state=="draining","3D short first segment plays on finish");
    check(bass.get_attribute(clients["stream3d"].stream->channel.stream,BASS_ATTRIB_VOL,&actual_gain)&&actual_gain==0,"short first finish preserves muted gain");
    check(wait_until([&](){return !clients["stream3d"].stream;}),"short 3D EOF ends");
    // 旧会话即便换 request_id 也不能恢复；同轮快照必须先于短尾音起播应用。
    auto new_session=make_start("new-session");auto session_at=new_session.find("\"session_id\":\"three\"");
    new_session.replace(session_at,std::strlen("\"session_id\":\"three\""),"\"session_id\":\"new-three\"");
    three_start(new_session);check(clients["stream3d"].stream!=nullptr,"new PCM session starts");
    write_text_atomic(three_dir/L"stream_command.json","{\"boot_id\":\"boot\",\"session_id\":\"new-three\",\"request_id\":\"new-session\",\"command_id\":1,\"action\":\"chunk\",\"chunk_index\":1,\"file\":\"short.bin\",\"bytes\":6400}");tick();
    write_text_atomic(three_dir/L"stream_spatial.json",snapshot("new-session",1,"0","[0,0,1]","[0,0,1]","[0,1,0]","boot","new-three"));
    write_text_atomic(three_dir/L"stream_command.json","{\"boot_id\":\"boot\",\"session_id\":\"new-three\",\"request_id\":\"new-session\",\"command_id\":2,\"action\":\"finish\"}");tick();
    check(clients["stream3d"].stream&&bass.get_attribute(clients["stream3d"].stream->channel.stream,BASS_ATTRIB_VOL,&actual_gain)&&actual_gain==0,"same-poll spatial gain is applied before finish starts audio");
    write_text_atomic(three_dir/L"stream_command.json","{\"boot_id\":\"boot\",\"session_id\":\"new-three\",\"request_id\":\"new-session\",\"command_id\":3,\"action\":\"stop\"}");tick();
    three_start(make_start("stale-session"));check(!clients["stream3d"].stream&&read_file(three_dir/L"stream_response.json").find("stale_session")!=std::string::npos,"retired PCM session cannot return");
    for(auto& [_,client]:clients){for(auto& [id,ch]:client.channels)free_channel(bass,ch);if(client.stream)free_channel(bass,client.stream->channel);}
    bass.free();std::filesystem::remove_all(root);
    std::cout << "PASS: real BASS file compatibility, 2D/3D push PCM, independent spatial snapshots, live gain 0-5, 105 chunks, two underruns, short tail, lifecycle and isolation\n";
    } catch(const std::exception& e) { std::cerr << "FAIL: " << e.what() << std::endl; return 1; }
}
