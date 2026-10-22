# REFAudio 独立客户端协议

2026-10-11：真实 BASS 流式 3D、独立空间快照和动态增益已实现；原生测试通过。游戏听感需要调用方接入后验证。

## 能力发现与所有权

先读取 `reframework/data/REFAudio/audio_backend.txt`，按制表符拆分字段，并取得本次进程的 `boot_id`。3D PCM 必须同时发现 `streaming_pcm=1`、`streaming_3d=1`、`stream_protocol=1`、`stream_spatial_protocol=1`、`stream_spatial_gain=1`。完整文件 3D 使用独立的 `client_spatial3d/client_spatial_gain` 能力，不可代替流式能力。旧 DLL 缺少能力时调用方继续使用 2D PCM。

每个项目拥有 `REFAudio/clients/<client_id>/`，标识允许 1–64 位 ASCII 字母、数字、`_`、`-`。每客户端一个 PCM 流，完整文件通道可与其共存。最多 16 个客户端、全设备 32 个活动流（含旧入口、文件和 PCM）。同一客户端的 mailbox 文件须由单一写者协调。

所有 BASS 操作由音频工作线程执行。REFAudio 不访问游戏 SDK，不持有随从、相机或其他游戏对象。**监听者是 BASS 设备级共享状态，不是每流独立状态**；所有 3D 客户端应使用同一游戏相机和坐标约定。声源、增益和 stop 在客户端间隔离，不修改全局距离/方向因子。

## 完整文件邮箱（兼容接口）

向 `command.txt` 原子写入一行制表符分隔正文：

```text
boot_id<TAB>session_id<TAB>递增request_id<TAB>action<TAB>local_channel<TAB>参数...
```

`request_id` 为正整数。`load` 参数为相对 `reframework/data` 的路径、音量、速度、最大秒数（0 不限制）。`load3d` 继续追加声源 XYZ、reference/max distance、监听者 XYZ、front XYZ、top XYZ。`position3d` 参数为声源 XYZ、监听者 XYZ、front XYZ、top XYZ，可再追加当前增益。支持 `volume`、`stop`、`stop_client`、`status`；`stop_client` 同时停止自有文件与 PCM。旧共享入口 `stop_all` 仍停止所有客户端。

`response.txt`：`boot<TAB>session<TAB>request<TAB>local_channel<TAB>ok/error<TAB>错误码或-`。检查完整身份匹配再处理 ACK，超时只能重发相同 ID 和相同正文。相同请求不同正文为 `request_conflict`。`state.txt` 每行是 `boot/session/channel/state/seconds/error`，自然结束保留 `ended`。示例见 `tool/REFAudioMailboxExample.cs`。

## PCM 启动

所有 JSON 控制文件用无 BOM 的 UTF-8，在同目录写临时文件后原子替换。最大 8 KiB；拒绝半写、重复键、非有限数值。协议 ID 必须符合上述 ASCII 约束。音频命令 ACK 与空间回执互相独立，调用方不可等待空间 ACK 才发送 PCM。

`stream_start.json`：

```json
{
  "boot_id": "audio-boot",
  "session_id": "stream-session",
  "request_id": "stream-request",
  "local_channel": 0,
  "format": "pcm_s16le",
  "sample_rate": 32000,
  "channels": 1,
  "bits_per_sample": 16,
  "volume": 2,
  "speed": 1,
  "max_duration_seconds": 60,
  "prebuffer_ms": 500,
  "stream_directory": "DeepSeekCat/tts-stream/stream-request",
  "spatial": true,
  "source": [0, 0, 1],
  "listener": [0, 0, 0],
  "front": [0, 0, 1],
  "top": [0, 1, 0],
  "reference_distance": 1.5,
  "max_distance": 40
}
```

`spatial` 可省略，默认 false；原 2D 单/双声道输入无需新增字段。3D 仅接受单声道，创建 `BASS_SAMPLE_3D + STREAMPROC_PUSH=-1`，不会静默回退 2D。3D 的四个向量和两个距离必须完整提供，坐标每分量绝对值不超过 1,000,000；方向非零、归一化前夹角余弦绝对值不超过 0.15，校验后归一化。reference distance 为 0.000001–1,000,000，max distance 不小于 reference distance，且不超过 1,000,000。坐标沿用完整文件接口，不另行翻转轴。

采样率为整数 8000–96000，16-bit little-endian；音量 0–5，速度 0.1–8，最大秒数 0–3600，预缓冲 80–500 ms，建议 500 ms。目录及块路径相对 `reframework/data`，禁止绝对路径、`..`、冒号以及越界符号链接。`stream_directory` 是调用方组织块文件的目录元数据；每条 chunk 的 `file` 仍须提供相对 data 根目录的路径。

启动结果写入 `stream_response.json`，`command_id=0`。活动流存在时等待其 finish 排空或 stop 后再启动新流。每次新语音使用新 request_id；同一 session/request 在当前 boot 内不能重新创建流，即使 start 正文改变也不重播。新会话停用旧会话后，旧 session 不可重新启动。每 boot 最多记录 8192 个请求和 64 个已停用会话。

## PCM 命令及确认

`stream_command.json`：

```json
{
  "boot_id": "audio-boot",
  "session_id": "stream-session",
  "request_id": "stream-request",
  "command_id": 2,
  "action": "chunk",
  "chunk_index": 1,
  "file": "DeepSeekCat/tts-stream/stream-request/chunk-0001.bin",
  "bytes": 12800
}
```

`action` 为 `start/chunk/finish/stop`。`start` 只确认已经创建的流；`chunk_index` 从 1 严格递增、最多 8192 块，不能丢块或重复送入。单块最多 1 MiB、长度与 bytes 一致且是 PCM frame 的整数倍；未播放数据上限 8 MiB。`command_id` 为 1–2^53−1 的递增整数；等待上条音频 ACK 后再发布下一条。重试最近请求必须使用完全相同的正文。冲突/旧命令不改变当前序号或播放状态。

`finish` 使用 `BASS_STREAMPROC_END=0x80000000` 封口。初始段不足预缓冲或断流后的短尾段，finish 也会用 `play(FALSE)` 从当前位置起播/续播，进入 draining，播放结束才 ended。stalled 时暂停，追加至少 max(预缓冲, 500 ms) 后续播；finish 不必等满阈值。不开新流、不 seek、不 `play(TRUE)`。stop/ended/error 释放 BASS 资源。

`stream_response.json` 示例：

```json
{"boot_id":"audio-boot","session_id":"stream-session","request_id":"stream-request","command_id":2,"status":"ok","consumed_bytes":0,"buffered_bytes":12800,"error_code":null}
```

错误包括 `invalid_parameter`、`invalid_path`、`spatial_requires_mono`、`boot_mismatch`、`stale_session`、`request_conflict`、`stale_request`、`stream_inactive`、`chunk_out_of_order`、`stream_already_finished`、`buffer_full`、`channel_limit`、`client_limit`、`request_limit`、`session_limit`、`io_error`、`bass_*`。输入/顺序错误只拒绝该命令，BASS 播放错误进入 error 并释放资源。不得使用旧身份请求操作新语音。

## 独立空间快照

每 100–200 ms 发布 `stream_spatial.json`，即使没有新 PCM、处于 buffering/rebuffering/draining 也可更新：

```json
{
  "boot_id": "audio-boot",
  "session_id": "stream-session",
  "request_id": "stream-request",
  "revision": 25,
  "source": [0.2, 0, 1],
  "listener": [0, 0, 0],
  "front": [0, 0, 1],
  "top": [0, 1, 0],
  "volume": 1.4
}
```

四个向量、volume 和身份都必须完整有效。revision 为 1–2^53−1 的整数，严格递增但允许跳过中间快照；重复读取相同正文不重复操作；相同已应用 revision 不同正文报告 `revision_conflict`，旧版本报告 `stale_revision`。非法快照不推进 applied_revision，不改变上一次有效位置和增益，调用方可以修正后发布。旧 boot/session/request 报 `invalid_snapshot`，不能影响新流；终态匹配身份的快照报告 inactive。

`stream_spatial_state.json`：

```json
{"boot_id":"audio-boot","session_id":"stream-session","request_id":"stream-request","observed_revision":25,"applied_revision":25,"status":"ok","error_code":null}
```

status 为 `ok/error/inactive`，错误为 `invalid_snapshot/revision_conflict/stale_revision/stream_not_spatial/bass_spatial_*`。无法解析身份或 revision 时 observed_revision 为 0。状态用于诊断，无需逐位置等待 ACK；不占用 command_id/chunk_index，不修改 PCM 字节和断流统计，不改变音频状态。

volume 是已经由调用方计算好的实际增益，立即设置当前流，也保存在 buffering/rebuffering 中供后续播放使用；0 始终静音，拒绝负值、>5、NaN、Infinity。REFAudio 不添加距离下限计算。DeepSeekCat 可计算 `配置音量 × max(下限比例, min(1, 1.5 / 原始距离))`（近距离按 1），并把声源沿原方向投影至 reference_distance 内避免 BASS 二次距离衰减。其他客户端可以按自身需求传入真实距离，使用 BASS 原生距离衰减。场景切换、对象失效和 freshness 由调用方判断后 stop。

## 流状态与验证

`stream_state.json` 保留 starting/buffering/playing/draining/ended/stopped/error、received_chunks/consumed_chunks、received_bytes/consumed_bytes/buffered_bytes、duration_seconds、last_chunk_index、underrun_count/rebuffer_ms/error_code；增加 `spatial` 和最后成功应用的 `spatial_revision`。playing 表示已经满足预缓冲并启动真实 BASS，draining 表示 finish 后仍在排空，不代表已完成。

原生独立验收：在仓库根目录执行 `tool/test-refaudio-native.ps1`。使用真实 BASS 和临时文件，覆盖文件多声道下混/2D 兼容、2D/3D 两次断流与短尾音、空间属性和坐标、句柄/位置/字节不回退、动态增益 0/1/2/5、非法快照、重复/冲突/旧版本、105 块并行位置更新、纯 PCM 客户端发现、终态不重播及客户端隔离。测试不操作游戏配置。

DLL 更新后须重启游戏。游戏听感验收需要 DeepSeekCat 实际接入：确认 backend 三个流式 3D 能力均为 1，移动随从及旋转相机，检查方向变化、音量和尾音，提供 `stream_state.json` 与 `stream_spatial_state.json`。原生测试不能替代游戏内听感验收。
