# 封存应用真实 public BV / VideoToolbox 验证

- 系统：macOS 27.0.1 / 26A434 / arm64。
- 封存 exe SHA-256：`a204485ac136d8282ddfdd8ba1a317494135cc86d415fa5c233b4b00ea5664d0`。
- 仅应用自身恢复凭据；未通过 `security` 或其他 helper 直接读取用户 Keychain、未操作系统安全窗口、未修改 ACL；诊断进程正常退出 `0`。
- 数据：`live-bv-vt.json` 为原始脱敏报告，`live-bv-vt-summary.json` 为白名单汇总及限制说明。

执行命令（stdout/stderr 重定向到 `.build/live-playback`，默认静音）：

```sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin dist/integration/Manping.app/Contents/MacOS/Manping --diagnose-bvid BV1VVpo6gEYg --codec avc1 --quality 80 --hwdec-mode videotoolbox --fixed-viewport --seconds 40 --report docs/evidence/live-bv-vt.json
```

实际选中 `avc1.640032` / `qn=80` / bandwidth `1841713` / 1920×1080，AAC `mp4a.40.2`。viewport 为 1280×720，`hwdec-current=videotoolbox`，hw pixel format 为 `nv12`。40 秒诊断窗口结束时媒体时钟为 `35.7440625` 秒，CGL `frames=869`、`backgroundFrames=868`、`sampleFrame=840`、`sampleHash=976c96c794f7557d`，shader `linkFailures=0`。

共 36 个媒体秒 metricSamples（0–35）。`frame-drop-count` 与 `decoder-frame-drop-count` 所有已记录样本及终点均为 `0`；未记录 `mistimed-frame-count`。最终 residentBytes 为 `251265024`。报告保留两条事件：`correct-downscaling requires non-bilinear scaler` 和 CoreAudio input channel layout 失败；均无时间戳。未记录 decode/NAL 错误，decode 错误次数为 0、时间列表为空。依委派条件不追加 software control。

有效观察：VT 保持启用，时钟前进且 CGL 渲染计数非零，无记录的 decode/NAL 错误或 decoder/frame drop。播放时钟不能单独证明图像稳定。报告只提供一个终点 sampleHash，不支持计算区间 sampleHash 变化；未做主观像素验收。实际 EDR 输出属性为 `target-prim=bt.2020` / `target-trc=linear` / `target-peak=3248`，不据此宣称完成色彩或 shader 验收。

封存 CLI 的实现上下文仍为 Web WBI `/x/player/wbi/playurl`（request `qn=127`、`fnval=4048`，选取 `qn=80`）；该 endpoint 不在诊断报告中，未证明实际 AppToken REST `/x/player/playurl`。未下载媒体、未验证与其他样本 same-byte、未进行长期播放或其他 BV/codec/quality 验证。

report/stdout/stderr 本地扫描未发现 URL 或 credential pattern；stdout/stderr 均为 0 字节。没有源码修改、构建、commit、push 或 merge。
