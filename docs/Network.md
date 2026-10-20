# 网络与 CDN（2026-10-17）

## 为什么需要

在一台 M1 Max 的真实网络上实测：

- **主节点不可达**：B 站接口签发的主节点 `upos-sz-mirrorcosov` 连接超时。旧版只用这一个地址，mpv 会一直卡住，界面表现为“点开视频不播放”。
- **备用节点能用但从未被尝试**：接口同时给出了 Akamai 备用地址，以及多个只换 host 就能访问的 UPOS 镜像。
- **单节点速度差异大、波动也大**：华为云约 17–20 Mbps、阿里云海外约 12–67 Mbps，腾讯和华为的通用节点都不到 1 Mbps。同一节点前后两次测量可以相差 30 倍。

## 组成

| 部分 | 位置 | 作用 |
| --- | --- | --- |
| 候选与策略 | `ManpingCore/CDNCore.swift` | 主机名校验（只允许 `*.bilivideo.com`，排除 PCDN、302 和非默认端口）；只换 host、签名路径和参数原样保留；候选排序；选择、恢复和防抖规则；缓冲趋势判定；智能缓存计算 |
| 测速 | `ManpingCore/CDNProbe.swift` | 两阶段测速：初筛最多 8 个节点各 128 KB，最快 3 个再各测 1 MB；接口签发的备用地址（包括非 bilivideo 域名）按原样参与测速 |
| 多节点中继 | `ManpingCore/MediaRelay.swift` | 本机回环 HTTP 服务（仅 `127.0.0.1`，每条流用随机令牌）。媒体按 1 MB 分块，从多个节点并发拉取，按顺序交给 mpv。分块明显偏慢时向另一个节点发同样的请求，先返回的生效（对冲请求）。节点出错会冷却；403/404 冷却 2 分钟。支持 Range 和 seek；切换节点不需要重新加载播放器 |
| 节点学习与存储 | `ManpingCore/CDNStore.swift` | 自定义节点、停用节点、近期学到的节点（最多 24 个，30 天过期）、按网络环境分开保存的测速结果。不保存媒体 URL、签名或 Cookie |
| 调度 | `ManpingApp/CDNController.swift` | 播放前选节点，每秒检查缓冲健康，卡顿时恢复，网络变化时让结果作废，按需自动降画质 |
| 界面 | `ManpingApp/CDNPanel.swift`；设置 →「网络与 CDN」 | 控制条上的节点按钮（带健康指示点）；面板里有缓冲、实时速度、在用节点、卡顿次数，以及节点列表（测速结果、实时速度、手动指定、停用）、自定义节点和事件记录 |

## 规则

- **起播**：
  - 测速结果仍在有效期内时直接使用，不额外等待。
  - 没有可用结果时先做初筛：中继模式最多等 1.5 秒，单节点模式最多等 3.5 秒。最快的节点总是最先返回，所以即使初筛没做完，也能选出合适的节点池。
  - 持续传输复测在后台完成后，再调整节点池。
- **上游响应**：
  - 在响应头阶段校验状态码、`Content-Range` 起止位置和内容类型；
  - 正文读到请求窗口的大小就停止，不会因节点忽略 Range 而下载整段视频；
  - 短块或范围不符的响应会换节点重试；越界请求返回 416。
- **节点池**：
  - 最多 4 个节点，优先保留速度不低于最快节点 1/4 的。
  - 多 CDN 模式下至少保留 2 个节点（第二个不低于 2 Mbps），让慢块总有已测速的节点可以对冲。
  - 合计带宽低于码率 1.5 倍时（例如 8K），按速度继续补入不低于 2 Mbps 的节点。
  - 停用的节点和最近失速的 3 个节点会暂避。
  - 池里只剩一个节点时发生卡顿，会扩充节点池，而不是暂避这个唯一的节点。
- **自动切换**：新节点至少快 15% 才切换，避免来回抖动。
- **卡顿恢复**：
  - 提前恢复：前向缓冲低于 8 秒，且连续 8 秒以上持续下降。
  - 兜底恢复：播放器明确在等待缓冲超过 2.5 秒；刚加载或刚跳转后放宽到 4.5 秒。
  - 冷却：同一节点 15 秒内不重复恢复；换到其他节点后至少间隔 7 秒。
  - 中继模式下会从节点池中暂避最慢的节点，不需要重新加载；单节点模式会在当前位置用新节点重新加载。
- **智能缓存**：
  - 预读时长 120 秒；最近 5 分钟内有卡顿时增加到 180 秒。智能缓存开启时不再以「缓存秒数」设置（默认 300 秒）为下限：实测它会让 4K 番剧把整集读进内存（约 1.4 GB）。
  - 缓存上限按码率换算，以用户设置的缓存大小为下限，最多 1.5 GB。
  - 卡顿后恢复播放前的回填等待从 1 秒增加到 3 秒；卡顿 3 次及以上时为 5 秒。
- **自动降画质**：3 分钟内卡顿 3 次，且所有节点合计带宽仍低于码率的 1.1 倍时，降一档画质，同时保留同一编码家族。自动降档不会改写用户的画质偏好；之后每 2 分钟最多再降一次。

## 实测（2026-10-17，M1 Max）

- **单元测试**：22 个，覆盖以下内容：
  - 选择策略、测速和存储；
  - 中继的完整读取、Range、节点失败冷却、对冲请求和节点中途失效；
  - 越界 416、短块重试、停用的签发节点、注销后不再拉取；
  - 响应头阶段的 Range 校验与字节上限。
- **实网吞吐**（`CDNLiveTests`，默认跳过，需要设置 `MANPING_LIVE_SAMPLE_URL` 才会运行）：

  | 轮次 | 单节点顺序读取 12 MB | 中继读取 | 中继拉取的节点 |
  | --- | --- | --- | --- |
  | 第一轮 | 18.5 Mbps | 36.2 Mbps | 只用到华为（随后修复：选节点时同步占用在途名额） |
  | 修复后 | 2.1 Mbps（网络波动） | 84.2 Mbps | 阿里海外 9 MB、华为 3 MB |

  两轮中继读出的数据都与直接读取逐字节一致。
- **App 内真实播放**（匿名账号，最高 480P）：
  - 影视飓风 4K 样片：有缓存结果时约 3 秒起播，中继峰值约 54 Mbps，几秒内整段缓冲完，0 丢帧。
  - AVC、HEVC 切换均为 VideoToolbox 硬解。AV1 在 M1 Max 上是软解，菜单里标注“软解”，默认选流不会选 AV1。
  - 跳转后立即恢复播放；手动指定节点、恢复自动都即时生效。
  - 番剧（中国奇谭）约 5 秒起播。
  - 稳定播放时，AppModel 和 PlayerModel 每秒发出的重绘信号都是 0；修复前每秒 10 次以上，这是“菜单要点好几次”的主要原因。
- **尚未测试**：4K/8K/HDR/杜比视界/120 帧需要登录（部分需要大会员）。Debug 版每次构建签名都会变，读不到钥匙串里的登录凭据，需要使用者扫码登录后再测。

## 任务 B：本地故障注入（2026-10-18）

本轮环境、离线播放、power和75轮内存结果见 [Performance.md](Performance.md)。所有App均为独立arm64 Release：

| 用途 | 源码commit | App | 主程序SHA-256 |
| --- | --- | --- | --- |
| 修前离线与8种临时故障、持续stall | `a09c87c` | `.build/task-b/app/满屏.app` | `36e2f72e8d8401c0eb024645424071ea1b64cc343a07a63fa1527a20c9dd53dd` |
| 重试预算修复后的复测 | `71124e7` | `.build/task-b/app-fixed/满屏.app` | `2f0d1bfe6436b7042c27ade8331c74ee46901de412984428d1cfc8ddca807dab` |

诊断启动强制fixture，使用 `DebugUICredentialStore` / `DebugUITransport`，不读真实钥匙串、不访问真实账号，不上报历史/进度，不调用AI。`--skip-auth` 在性能诊断中也明确接受。`Application.swift:169` 起采用accessory与quiet窗口，禁止激活且点击穿透。普通 `live_check.py` 内有osascript前置窗口，故本轮未使用；实网匿名视频、直播、睡眠唤醒、真实代理/TLS/DNS均未测。

新增 `scripts/net_fault_server.py` 是仅回环绑定的HTTP Range媒体源，不是HTTPS代理。主源绑定127.0.0.1，备用独立绑定::1；MediaRelay的origin key只取host，同host换端口/路径会去重，不能伪装成两个节点。诊断URL严格限制上述literal地址、固定媒体路径，无用户名、密码、query、fragment，不接收远端URL或重定向。

`--perf-network` 通过真实 `CDNController.prepare/attach → MediaRelay → PlayerModel.load`，不开自动测速、不启用智能缓存；预读2秒、mpv前向上限4MiB，源站按16KiB块全局限速，防止并发请求乘出无限带宽。主/备共享总速率时钟，健康总速率为素材码率的1.15倍。未调用诊断恢复函数、seek或主动reload来制造恢复；CDN恢复和relay retry/hedge都来自生产逻辑。fixture没有完整画质候选，因此**没有验证自动降档实际换流**；回环URL不可换成真实bilivideo域名，因此没有验证生产域名替换或节点测速质量。

### 判定与命令

临时故障：首次HTTP媒体请求后第5–25秒注入，App运行60秒；必须实际命中故障、干净退出、出现实际渲染帧、故障结束后三个连续1Hz样本推进且无buffering/error，最后5样本至少3个推进、最后样本无错误/缓冲。表中“恢复确认”是从故障结束到**第三个连续推进样本**，包含约2秒确认时间和1Hz采样量化，不是精确的首帧恢复瞬间。健康对照无故障恢复时延。初始“首帧”同样有约1秒量化。

```sh
python3 scripts/network_stability_check.py --app .build/task-b/app/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 \
  --output .build/task-b/network-single --origins single --seconds 60 --bitrate 8158613
```

| 单来源临时场景 | 故障实际命中 | 首帧s | 最长不推进s（含起播） | 恢复确认s | CDN恢复 / relay重试 | CPU均% | 结果 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| healthy | 无故障对照 | 3.036 | 3.036 | — | 0 / 0 | 14.14 | 通过 |
| latency | 10次响应头各延迟3秒 | 3.040 | 4.067 | 4.606 | 1 / 0 | 28.48 | 通过 |
| throttle | 215个低速块，约1.41Mbps，低于8.16Mbps素材 | 3.056 | 20.401 | 3.549 | 2 / 2 | 43.68 | 通过恢复，CPU升高 |
| disconnect | 21次正文发送32KiB后断开 | 3.067 | 22.665 | 5.867 | 2 / 18 | 47.00 | 通过恢复，CPU升高 |
| stall | 316次等待，故障期间不发正文 | 3.017 | 22.523 | 5.653 | 2 / 2 | 46.77 | 通过恢复，CPU升高 |
| 403 | 21个HTTP403 | 3.051 | 20.478 | 9.830 | 2 / 18 | 47.42 | 通过恢复，CPU升高 |
| 404 | 21个HTTP404 | 3.070 | 20.501 | 9.848 | 2 / 18 | 48.03 | 通过恢复，CPU升高 |
| slow-start | 779个慢启动块，速率从健康的5%渐升 | 3.053 | 7.101 | 2.525 | 1 / 0 | 29.90 | 通过 |

8轮无崩溃、外部watchdog超时或播放错误，临时故障未变成永久等待。每轮关闭后源站active_requests=0；旧Player/Surface=0，显式清空引擎池后layer=0。RSS峰值约268–290MiB，清空池后约264–287MiB，只回落约2–4MiB，没有回到冷启动水平；这不是每轮新增同等泄漏的证据，也不是资源完全回收的证明。每轮独立进程，长期内存见75轮测试。原始JSON、1Hz状态、CPU/RSS CSV在 `.build/task-b/network-single/`。

### 持续首播等待与修复

修前复现：源站从首个请求开始完全停止正文、持续90秒，App观察45秒。媒体时间始终0，没有首帧、没有Player错误、CDN恢复计数0，**未通过有界错误提示目标**。该轮附带3秒sample，CPU不用于性能对照：

```sh
python3 scripts/network_stability_check.py --app .build/task-b/app/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 --bitrate 8158613 \
  --output .build/task-b/persistent-before --origins single --scenarios stall \
  --seconds 45 --fault-start 0 --fault-end 90 --expect-error --sample-at 15
```

根因证据：`MediaRelay.swift:511` 的每块10轮重试，原 `hedgedFetch` 的timeout按估算吞吐计算，失败后估速减半反而扩大后续timeout，整轮可能累积到分钟级（代码推导，未实测等待数分钟）。`CDNController.swift:612` 的恢复要求duration>0，首块元数据未返回时不会进入；`Player.swift:464` 只有收到mpv end-file失败才发布错误，因而45秒观察窗内未出现提示。

`71124e7` 在 `MediaRelay.swift:515` 增加默认30秒**每块重试启动软预算**，使用ContinuousClock；到期后不再开始新一轮，backoff截断到剩余预算，最后一轮失败不再空等。保留已开始请求和hedge的原timeout，避免硬30秒切断仍在传输的慢源。不是播放器30秒报错硬保证；后续一次已开始请求仍可能跨过预算。当前Fetcher没有过程字节进展API，精确“无进展超时”和首播整体deadline仍属后续设计项，不能用这个修复宣称已覆盖。

3个新回归在 `Tests/ManpingCoreTests/CDNTests.swift:236` 起：550ms预算耗尽仅2次尝试→502且inflight/连接归零；zero预算首个200ms慢请求仍成功、原timeout≥8秒；unregister取消真实活动请求后归零且不再重试。32项CDN测试通过；修后完整 `swift test` 为 **508项、5跳过、0失败**（21.788秒）。没有改播放器渲染、代理配置或账号状态。

修前持续stall日志中的active_requests=4是旧故障服务器刻意等待正文时未检查客户端断开的handler数，不能当成App取消失败证据。`e0c713a` 给server补充断开检测及回归测试；临时8轮已有active=0，修后采用修正采集器的各轮也均为0。所有测量文本去除绝对路径、凭据头及relay随机能力URL，未提交原始产物。

修后反例不能隐去：同样持续stall观察45秒仍无首帧、无Player错误；持续403观察35秒也无错误。因此**首播有界提示目标仍未通过**，`71124e7`只修复单块重试放大，没有解决整个播放器等待。stall日志31.456秒中继连接降至0、32.468秒又变为1；403在首批10次失败后又出现新读取，35秒累计19个403。这支持上层新读取会重新获得每块预算，未完整追踪到mpv/FFmpeg具体重试函数，不把它说成已定位到某个上游源码缺陷。

| 修后持续故障，首请求起第0–90秒注入 | App观察 | 首帧 / Player错误 | 请求 / relay重试 | 关闭后活动请求 / 旧对象 | 30秒错误门禁 |
| --- | ---: | --- | ---: | --- | --- |
| stall | 45秒 | 无 / 无 | 4 / 2 | 0 / 全部0 | 未通过 |
| 403 | 35秒 | 无 / 无 | 19 / 16 | 0 / 全部0 | 未通过 |

建议下一步在Player加载会话层设计整体首播deadline并取消整个读取会话，绑定load generation，覆盖用户暂停、seek、换质、慢而持续有进展的来源；或先让fetcher暴露字节进展，做真正的无进展期限。仅加每块硬超时会误伤可用慢源，仅加每块软预算又无法阻止新读取。这涉及播放生命周期和取消语义，按任务约束留待决策，没有继续叠加未经验证的超时补丁。

修后命令（`CASE`、输出目录和参数可按下表选择；完整实际命令另存 `.build/task-b/post-runs.json`）：

```sh
python3 scripts/network_stability_check.py --app .build/task-b/app-fixed/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 --bitrate 8158613 \
  --output .build/task-b/persistent-after --origins single --scenarios stall \
  --seconds 45 --fault-start 0 --fault-end 90 --expect-error
python3 scripts/network_stability_check.py --app .build/task-b/app-fixed/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 --bitrate 8158613 \
  --output .build/task-b/transient-after --origins single --scenarios stall 403 disconnect --seconds 45
python3 scripts/network_stability_check.py --app .build/task-b/app-fixed/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 --bitrate 8158613 \
  --output .build/task-b/backup-after --origins backup --scenarios stall 403 404 disconnect \
  --seconds 45 --fault-start 0
```

修后临时stall/403/disconnect三轮分别4.600/5.752/4.652秒确认恢复，全部通过，关闭后active=0且旧Player/Surface/清空池后的layer=0；没有把持续故障失败替换成这些临时成功结果。

### 备用节点接管与资源

主来源从首请求开始故障0–25秒，备用来源始终健康，App观察45秒；四轮均实际命中主故障且备用交付字节数>0。不是仅配置了一个未被使用的备用地址。

| 修后双来源 | 首帧s | 最长不推进s | relay重试 / hedge | 备用实际交付bytes | CPU均% | 结果 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 主stall | 6.175 | 6.175 | 0 / 6 | 44,990,464 | 22.20 | 通过 |
| 主403 | 3.076 | 3.076 | 1 / 0 | 52,297,728 | 19.24 | 通过 |
| 主404 | 3.057 | 3.057 | 1 / 0 | 50,479,104 | 18.06 | 通过 |
| 主断流 | 3.069 | 3.069 | 2 / 0 | 43,270,144 | 18.13 | 通过 |

四轮无播放错误或崩溃，关闭后源站活动请求0，旧Player/Surface/清空池后的layer全部0。JSON/日志/CSV在 `.build/task-b/backup-after/`。临时故障最终恢复、备用接管和资源取消均有证据，但单个来源一直失败时的首播提示仍未通过，不能合并宣布“网络稳定性全部通过”。

### 卡顿高CPU：定位到libmpv AVFoundation音频路径，未修改依赖

正式60秒单来源轮中，健康CPU均14.14%，限速/断流/stall/403/404为43.68–48.03%。另起独立profile轮，第15秒用 `sample <本次子进程pid> 3 1`；该轮CPU排除在正式对照之外。throttle在第15秒处于buffering，健康对照同一阶段正常推进。

```sh
python3 scripts/network_stability_check.py --app .build/task-b/app-fixed/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 --bitrate 8158613 \
  --output .build/task-b/profile-throttle --origins single --scenarios throttle \
  --seconds 45 --sample-at 15
python3 scripts/network_stability_check.py --app .build/task-b/app-fixed/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 --bitrate 8158613 \
  --output .build/task-b/profile-healthy --origins single --scenarios healthy \
  --seconds 30 --fault-end 15 --sample-at 15
```

3秒throttle栈中，`avfoundation event`串行队列的1196个快照持续处于执行路径；其中757个在 `AVMediaDataRequester _requestMediaDataIfReady` 分支，613个进入libmpv `__start_block_invoke`，424个在某一 `AVSampleBufferRenderSynchronizer currentTime` 分支。主线程1048/1196个快照在mach等待。健康栈全文没有上述队列/请求回调热点。这些是栈分布，**不能将1196个快照换算成100%CPU**。

本地已锁定mpv 0.41.0源码 `audio/out/ao_avfoundation.m:61–87` 的 `feed`：无PCM、非EOF时 `ao_read_data` 返回0，仅释放buffer返回；只有EOF才 `stopRequestingMediaData`。`:149` 注册的ready回调仍在；SDK说明会持续调用直到取消。`audio/out/buffer.c:124–131,189–193` 的空队列路径会返回0并将playing置false，支持回调反复取时钟/分配释放而没有可消费PCM的因果解释。该证据将主要疑点指向音频饥饿回调循环，**不支持直接归咎于SwiftUI加载动画**；也没有证明全部额外CPU都来自唯一函数。

建议独立处理libmpv的零样本供给停止/重启策略，覆盖缓冲恢复、EOF、pause、设备切换；或先做已有CoreAudio输出的受控A/B。修复涉及第三方音频回调与依赖重建、patch/lock/hash更新，超出本任务允许写入范围且有音频恢复风险，因此没有修改 `patches/`、依赖锁或默认音频后端。原始脱敏stack分别在 `.build/task-b/profile-throttle/`、`.build/task-b/profile-healthy/`。

### 工具与范围

独立服务：`python3 scripts/net_fault_server.py --media .build/perf-media/testsrc2-h264-1080p30.mp4 --scenario stall --backup --seconds 75`，只打印本次回环端点与标量计数，不提供任意路径文件服务。`network_stability_check.py` 默认跑全部8场景，可选 `--origins single|backup|both`、`--fault-start/--fault-end`、`--sample-at`；`--expect-error` 使用严格30秒Player错误门禁，持续失败例会返回1，不能因为App正常退出就视为通过。所有测量输出路径强制在 `.build/`；源站不记录请求头内容，credential_header_requests只记是否存在凭据头，本轮各次均为0（未出现该计数即0）。

`python3 scripts/net_fault_selftest.py`：9项通过（精确Range、suffix/HEAD、416、403/404与恢复、IPv6独立备用、正文断流、stall恢复、取消、参数）；`python3 scripts/diagnostic_checks_test.py`：2项通过（日志隐私/相对路径与掉帧失败传播）。Swift独立lint入口未发现；用Swift编译与完整tests、Python语法检查、`git diff --check`验收。HTTP回环实验没有覆盖真实代理隧道、TLS/CONNECT、CDN域名测速/替换、直播聊天重连和真实降画质，不能推及这些路径。

## 任务 B 第二轮：有限恢复与匿名边界（2026-10-19）

本轮从 `6b453dc` 开始了解历史，保留其后的独立 README 提交 `66a273b`。最终测试源码 `b38eb51`，arm64 Release 包 `.build/task-b-v2/final/满屏.app`，主程序 SHA-256 `b102ea1881b264abd4fff4ba679e09ed2d097f23d28e9431913303b122178b68`。MacBookPro18,2 / M1 Max、10 CPU、64 GiB，macOS 27.0.1 (26A434)、Swift 6.4；ad-hoc 签名及 44 个库/FFmpeg 输入闭包验证通过。未替换或关闭正式 Release，未操作用户窗口、鼠标或系统网络。

### 修复及可核验边界

- `cad66d0`：`PlaybackRecovery.swift:12`、`:28` 使用单调时钟；首播 16 秒尝试恢复、28 秒终止，中途无推进 6 秒尝试、40 秒终止，403/410 在 2 秒触发尝试。显式暂停冻结等待，用户 seek 新建等待，自动 reload/降质不续期；EOF 不误报，terminal/取消不可被迟到回调复活。
- `CDNController.swift:692`、`:709`：终止时取消刷新/测速、注销 Relay、停止 mpv、清 buffering，复用 `Player.error` UI；一次播放最多重新获取一次 playurl，刷新失败或相同坏 URL 仍受原期限限制。UGC/PGC closure 分别在 `AppModel.swift:1872`、`PGCPlaybackModel.swift:259` 校验 generation/身份/播放器，关闭、换视频/P 和取消不会让旧结果重新加载。
- direct 模式使用有限候选序列，同主机不同签名也视为不同 URL，能遍历第三候选，不把失败候选放回队列；Relay 视频/音频/替换 URL 共享同一个 `RelayRetryBudget`。默认 45 秒累计失败传输/退避区间，重叠失败只计一次，健康播放年龄不扣预算，新 range 不获得新预算。定义在 `PlaybackRecovery.swift:72`，由 `CDNController.swift:98`、`:726` 持有并传递。
- `b38eb51`：已知单路音频 403/410 优先于视频进展；视频继续播放不能把等待不断清零。新增三项 policy 测试和一项真实 Relay 双 source 回环测试，确认视频成功不清除音频过期状态，只有该音频 source 成功才清零。这一细分依据代码复核与单测，未单独做双流 App 故障实播。
- `b8071e3`、`d933e86`：直播重连最多 8 次，退避 1/2/4/8/16/16/16/16 秒；第 9 次请求进入终态，停止 watchdog、加载与播放器。非终态只有连续健康推进 20 秒才清重试，暂停、卡住或采样间隔超过 2.5 秒会打断窗口；终态不能被健康 tick 或“下播→开播”消息复活，手动刷新/换质可重新开始。见 `LiveReconnectBudget.swift:3`、`LivePlaybackModel.swift:261`、`:349`。直播错误循环依靠单测和代码复核，回环点播矩阵不等于直播聊天重连实测。

### 匿名实网尝试：安全门禁通过，播放未完成

匿名路径使用独立 `BiliService`，`DenyCredentialStore` 无任何真实存储；`GETOnlyAuditedTransport` 只允许固定 host/path/query/header 的公开 GET，拒绝账号 Cookie、Authorization、body 和重定向，剥离响应 Set-Cookie。外壳保持 fixture，`AppModel.swift:1619` 跳过 progress reporter/watch activity/system media 启动；直播只运行媒体，不启动 chat/WebSocket/心跳。AI 使用内存 fixture，未调用付费 AI。

`config=no` 本身不会关闭内置 `ytdl_hook`，媒体失败仍可能启动继承用户配置的外部提取器。`13eb526` 因此只在性能诊断引擎初始化前 fail-closed 设置 `ytdl=no`、`load-scripts=no`、`cookies=no`，初始化后实际读回三项全部为 no 才返回引擎，匿名第一条真实 API 前再次检查并记录 MEDIA 证据。普通非诊断初始化行为不变。CDN transport 同时明确 `urlCredentialStorage=nil`；原 `.ephemeral` 默认已是私有内存凭据库，此项是固化契约，不是已观测到持久 Keychain 读取。

`scripts/media_isolation_check.py` 对真实 C bridge 的 9 个 fake API 成功/失败分支通过；另一次 35 秒持续 403 的真实 quiet App 回环，收到 13 次 403 后进入终态、buffering 清零。假的 yt-dlp 控制调用成功，播放期间 helper marker 未生成；没有运行真实提取器。证据 `.build/task-b-v2/media-isolation-loopback/summary.json`。

```sh
python3 scripts/anonymous_playback_check.py --app .build/task-b-v2/final/满屏.app \
  --bvid BV1fK4y1t7hj --seconds 330 --output .build/task-b-v2/anonymous-video
python3 scripts/anonymous_playback_check.py --app .build/task-b-v2/final/满屏.app \
  --live auto --seconds 330 --output .build/task-b-v2/anonymous-live
```

| 目标 | 实际结果 | 诊断起点至关闭 s | 首帧/卡顿 | 尝试整轮 CPU % | RSS 峰 MiB | GET 数 | 凭据/非GET/拒绝 |
| --- | --- | ---: | --- | ---: | ---: | ---: | --- |
| BV1fK4y1t7hj | FAIL，transport | 60.459 | 未起播，无法统计播放卡顿 | 2.784 | 169.125 | 2 | 0/0/0 |
| 自动公开直播 | FAIL，transport | 30.490 | 未取得 room/media，无法统计 | 4.666 | 170.875 | 1 | 0/0/0 |

两次 App 退出码均为 0、无外部 watchdog 超时，runner 正确返回 1；首尾匿名身份、凭据计数及媒体隔离均通过。drain 后旧 Player/Surface/layer 均为 0。上表 CPU 是失败尝试数据，**不能代表播放 CPU**。没有完成任一 330 秒实播，不宣称实网稳定通过；固定错误分类没有保留原始 NSError/URL，不能据此断言 Bilibili 服务故障或具体 DNS/TLS 原因。没有在相同 transport 失败后盲目换 BV 重试。

API 计数只覆盖独立 service 的 API transport；CDN/mpv 走独立媒体路径，所以这不是全进程网络审计。媒体路径依据初始化选项读回、无 Cookie/凭据 fetcher 和关闭外部提取器的证据约束。日志只保存公开目标 ID 和固定标量，不保存媒体 URL、请求头、Cookie/Token。

### 指定清理条目逐项复核

| 编号 | 处理 | 有意保留及原因 |
| --- | --- | --- |
| 035 | 删除重复嵌套 DEBUG | 外层 DEBUG 保留 |
| 036 | 删除不可达 macOS 14 fallback | 部署目标 macOS 27 |
| 037 | 删除 `--ui-network-probe`/runNetworkProbe | 新故障脚本不依赖；无真实消费者 |
| 038 | 删除 stability 重复 case 3 | default 仍导航 downloads |
| 049 | 删除无引用 LiveChatModel.clear | — |
| 059 | chatEvents/chatHasBuvid 及写入限制为 DEBUG | DebugPlaybackReport 有真实读取 |
| 092 | status 去掉 Published | 保留普通诊断字段和真正的 Player.error 发布 |
| 093 | 删除 force 参数、每次失效并重算 smart cache | 保留 multiSource 变化提示；复核发现诊断原有 false 调用，未照旧审计盲删行为 |
| 095 | 删除 legacy display updates/timer 对照开关 | 默认 CVDisplayLink、render 锁、250ms idle 检查保留 |
| 096 | 删除无引用 mediaClock(at:) wrapper | mediaClock property 有真实消费者 |
| 097 | 删除只写 clockUpdated | — |
| 099 | 删除 currentPool.issued/bestKey.issued/directURLs.sample 无用参数 | — |
| 100 | 删除 CDNHealth.stalls 无用参数及两处传参 | — |
| 101 | 修正文档注释位置、重复注释和旧设置菜单名称 | 使用「更多 › 网络与节点」 |
| 108 | 慢诊断属性只在诊断模式读 | 正常时间/音频平滑时钟、cache/state/EOF、gamma/aspect 保留 |
| 110 | 删除无人消费的 Shadowsocks Stats/counters/onEvent/warmCount/currentListener | health/probe/rebuild/onRebuilt 和同步保留 |
| 115 | 删除被忽略的 SmartCachePolicy.userSeconds 传参链 | 真实 MpvRuntimePlan cacheSeconds 设置保留 |
| 116 | 删除 hosts、pick 无用参数；仅测试接口改 internal | activeConnections/connections 已有生产诊断用途，保留；原子 inflight 预留和 cooldown 保留 |
| 117 | prewarm 恒真分支简化，poolSize 固定私有 2 | 原预热/健康补池行为保留 |
| 119 | 删除无引用 CDNStore.setCustom | — |
| 120 | 删除无引用 CDNURLSessionFetcher.totalLength | 实际 contentRange 解析保留 |

这 21 项均已复核处理；表中部分字段按真实引用保留，没有未处理条目。另两项性能清理 `044`、`010` 及 CPU 实测详见 [Performance.md](Performance.md) 第二轮章节。Markdown 单测证明解析缓存复用，不代表完成真实 AI 流式 UI CPU 测量。

### 工具与本地提交

`network_stability_check.py` 现在支持 410、一次刷新 healthy/same/same-with-backup/cancel、direct 第三候选，以及音频/A-V/阶段 CPU 和媒体隔离门禁。持续错误要求从故障起点 30 秒内终态并停止 buffering/连接；中途持续 stall 可显式给 50 秒预算，包含已缓存媒体推进。瞬时故障仍要求原来的三次连续推进及最后五次中至少三次推进，最后无错误、无缓冲；不能放宽为“进程正常退出”。

`network_stability_suite.py --extended` 保留原 20 轮配置并增加 8 轮；historical before/after-reference 是旧场景标签，两轮都使用当前最终包，不混入旧二进制。三个 sample 诊断轮排除 CPU 比较。完整回归命令：

```sh
python3 scripts/network_stability_suite.py --app .build/task-b-v2/final/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 --bitrate 8158613 \
  --output .build/task-b-v2/network-final --extended
python3 scripts/media_isolation_check.py --self-test --output .build/<NEW_DIR>
python3 scripts/media_isolation_check.py --app <APP> --library <PINNED_LIBMPV> \
  --output .build/<NEW_DIR>
```

输出目录必须在 `.build/`；suite、匿名 runner 和隔离检查要求新目录。`--plan-only` 只生成计划，不是播放验收。未覆盖 HTTPS CONNECT、系统 DNS 故障注入、真实代理隧道、硬件切换或生产自动降质实测。

| Commit | 主要变化 | 提交后 Swift tests / skipped / failures |
| --- | --- | --- |
| cad66d0 | 首播/中途有限恢复、一次 playurl 刷新、跨读取 Relay 预算 | 516/5/0 |
| 862d289 | PGC 当前内存设置读取 | 516/5/0 |
| f3a6d34 | Markdown 有界解析缓存 | 519/5/0 |
| a197c74 | 指定网络/播放冗余清理 | 519/5/0 |
| b8071e3 | 直播重连预算与连续健康窗口 | 522/5/0 |
| 05bc07b | 匿名与音频测量 runner、28 轮计划 | 529/5/0 |
| 12e56ab | CoreAudio 两行 API 修正及 hash/lock | 529/5/0 |
| d933e86 | 直播消息不能解除重连终态 | 531/5/0 |
| 13eb526 | 诊断媒体隔离、无凭据 CDN 契约 | 531/5/0 |
| b38eb51 | 音频过期优先于视频进展 | 535/5/0 |

各 commit 提交后 `swift build`、`swift test`、`python3 scripts/privacy_check.py` 均通过，隐私 0 findings；没有 push。5 个 skip 是可选实网 CDN/API、实 FFmpeg merge、真实代理及代理 serve 测试所需环境未启用，不把它们算成实测通过。新增离线 Cbridge 自测 9 分支，源站自测 10 项，原诊断自测 2 项，Python 语法与脚本 self-test 另行验证。App 资源/二进制隐私扫描也为 0 findings。

### 最终完整矩阵：28/28，通过（同一最终包）

命令见上节，产物 `.build/task-b-v2/network-final/summary.json`；`plan_only=false`，suite 退出 0。原 20 轮全部通过：原来的 17 个通过场景无功能退化，两个持续首播 stall 和一个持续 403 的失败场景全部变为有限错误；另 8 轮扩展也通过。28 轮 App 退出码均 0，无崩溃、无外部 watchdog 超时；三个 sample 调用退出码均 0。

首帧是下一次 1Hz 观察到渲染及推进的上界，相对 App network START。表中「结束+」是源站故障结束后满足连续三次推进门禁的时间；健康轮仅沿用同一参考时刻，不表示发生故障。「新源+」从健康备用源实际首字节算起；「错误+」从源站故障开始算起。备用轮往往早于故障结束就已起播，不能把门禁时间当成精确切源延迟。

| # | 场景（名称中的数字为观察秒数） | 首帧 s | 门禁相对时间 s | 整轮 CPU % | RSS ps峰→drain MiB | 结果 |
| --- | --- | ---: | --- | ---: | ---: | --- |
| 1 | single-60-healthy | 2.049 | 结束+2.837 | 12.40 | 284.05→282.17 | PASS |
| 2 | single-60-latency | 2.052 | 结束+2.629 | 14.63 | 279.73→277.72 | PASS |
| 3 | single-60-throttle | 2.057 | 结束+3.694 | 14.60 | 275.00→272.53 | PASS |
| 4 | single-60-disconnect | 2.077 | 结束+6.840 | 15.28 | 268.19→265.78 | PASS |
| 5 | single-60-stall | 2.062 | 结束+4.757 | 15.44 | 271.27→268.83 | PASS |
| 6 | single-60-403 | 2.064 | 结束+7.740 | 15.64 | 268.50→266.56 | PASS |
| 7 | single-60-404 | 2.045 | 结束+7.742 | 15.42 | 266.61→264.12 | PASS |
| 8 | single-60-slow-start | 2.057 | 结束+2.674 | 14.22 | 280.61→278.78 | PASS |
| 9 | single-45-stall | 2.053 | 结束+4.816 | 15.96 | 253.09→251.25 | PASS |
| 10 | single-45-403 | 2.058 | 结束+7.800 | 16.71 | 251.44→249.53 | PASS |
| 11 | single-45-disconnect | 2.064 | 结束+6.751 | 16.19 | 250.05→248.17 | PASS |
| 12 | backup-45-stall | 4.115 | 结束+2.686 | 14.03 | 265.45→263.66 | PASS |
| 13 | backup-45-403 | 2.036 | 结束+2.623 | 13.84 | 276.58→274.69 | PASS |
| 14 | backup-45-404 | 2.033 | 结束+2.642 | 12.58 | 277.08→275.50 | PASS |
| 15 | backup-45-disconnect | 2.050 | 结束+2.694 | 13.26 | 277.45→275.36 | PASS |
| 16 | profile-throttle | 2.046 | 结束+3.795 | —¹ | 254.41→252.03 | PASS |
| 17 | profile-healthy | 2.042 | 结束+2.341 | —¹ | 261.33→258.98 | PASS |
| 18 | persistent-stall-before-reference | — | 错误+28.665 | —¹ | 169.81→169.25 | PASS |
| 19 | persistent-stall-after-reference | — | 错误+28.780 | 2.75 | 168.86→168.67 | PASS |
| 20 | persistent-403 | — | 错误+28.787 | 3.23 | 169.17→168.98 | PASS |
| 21 | persistent-410 | — | 错误+28.727 | 3.82 | 169.66→169.44 | PASS |
| 22 | midstream-persistent-stall | 2.049 | 错误+43.874 | 13.66 | 226.08→225.89 | PASS |
| 23 | relay-403-refresh-healthy | 4.046 | 新源+4.107 | 12.00 | 263.42→261.73 | PASS |
| 24 | relay-403-refresh-same | — | 错误+28.738 | 3.95 | 169.72→169.52 | PASS |
| 25 | relay-403-refresh-cancel | — | 错误+28.727 | 3.23 | 169.53→169.42 | PASS |
| 26 | direct-403-third | 3.099 | 新源+3.125 | 11.50 | 218.84→217.17 | PASS |
| 27 | direct-403-refresh-same-with-backup | 2.033 | 新源+3.065 | 12.22 | 219.12→217.27 | PASS |
| 28 | direct-403-backup | 2.054 | 新源+3.117 | 12.24 | 220.77→218.81 | PASS |

¹ 三个 profiling 轮 CPU 不参与性能比较。预期错误轮可在无音频/无首帧时通过有限错误门禁，它们较低的 CPU 也不能作为音频优化证据；音频有效的同代码对照见 Performance.md。

原三轮反例的错误时间分别为 28.665、28.780、28.787 秒，均小于 30 秒门禁，终态 buffering=0、Relay connections/inflight=0，持续到观察结束。中途持续 stall 在故障后 43.874 秒报错，包含故障后缓存仍可推进的时间，满足 50 秒门禁；恢复策略本身从最后有效推进起算 40 秒。

刷新到健康地址：refresh=1、reload=1、首帧 4.046 秒；刷新仍坏：不续期，28.738 秒终态；刷新取消：refresh=1、reload=0，28.727 秒终态。direct 第三候选：前两项失败、reload=2，第三项实际提供媒体，首帧 3.099 秒。第 27、28 轮分别曾在 1.001、1.026 秒采样到暂态 Player.error，随后自动重载清除，最后持续推进且无错误；通过标准允许恢复过程中的暂态错误，没有把它们描述为全程无错误。

全部 28 轮最终上游 active_requests=0，原始源站 credential_header_requests 合计 0。drain 后旧 Player、Surface、video layer 均为 0；第一次 settle 时引擎池仍保留一层是预期生产复用行为，之后显式 drain 再观察。

RSS settled→drained 在 28/28 轮均下降，但只有 0.047–1.609 MiB；drained RSS 范围为 168.672–282.172 MiB。各轮是独立进程、状态不同，不能把跨轮高低排列当成长时间内存趋势，也不能把对象为 0 等同于全部底层内存回收。上一轮长循环 vmmap/leaks 未在本轮重跑，相关未达结论仍保留。

## 第三轮审查修复与最终复验（2026-10-19）

本节更正前轮有限错误的验收证据：`first_error_s` 可以是随后清除的暂态错误，不能证明恢复策略已终止或底层传输已停止。上节历史数字保留；本轮期限以首次同时满足真实 terminal、引擎停止与源站安静的样本计算，不沿用旧错误时间作为收敛时间。

最终应用源码为 `8ee2df0000faa535b81a3d357f458329ce2c6163`，包 `.build/task-b-v3/final-v3/满屏.app`，主程序 SHA-256 `d326a50edaf437d0370a7efc18ff96f5367b50bf3677111131ce1f5aff280a60`；libmpv SHA-256 仍为 `0dbc9892072183222e42b060e852a2e1047e2b47c8b3905d905b02805c0a3624`。输入锁的 44 个库、FFmpeg/mpv 输入及 46 个最终签名哈希、arm64、依赖闭包、无 Homebrew RPATH、strict 签名和包隐私检查均通过。构建使用 Xcode 的 `DEVELOPER_DIR` 与 `MANPING_SIGN_IDENTITY=-`。

主工作区保留外部 `DemoDirector.swift`、`M8AITemplateSettingsView.swift`、`docs/media/remotion/render.mjs` 及未跟踪 `.claude/`、`docs/images/`，均未由本任务修改或暂存。新增外部 M8 文件引用尚不存在的 `AIPromptTask.title`/`Identifiable`，使主工作区构建失败。最终修复的 pre/post gates 和包构建改在 `.build/task-b-v3/isolated-source` 的干净 detached commit 源码执行，复用本地依赖缓存并禁用依赖自动更新；外部源码没有进入最终包。这里不宣称主脏工作区构建通过。临时源码在全部验证后清理，包与脱敏证据保留。

### 修复内容与可重复反例

| Commit | 变化 |
| --- | --- |
| `bd3fef9` | 公开真实 policy terminal 和单调进入时间；抽取 runner 实际消费的终态判据 |
| `642dbaf` | 首帧等待跟随实际 owning surface/window 的呈现预期；隐藏时仍要求真实媒体时间推进 |
| `879bf15` | 自动 direct 恢复遵守手动节点及 stallRecovery；刷新后按当前 policy 重新过滤；Relay 发请求前动态限制 manual host |
| `13100d0` | 诊断在既有 mpv queue 读取真实 idle/time-pos，并逐样本记录全部本地源站累计请求、字节与活动数 |
| `82a9f19` | Application 外层诊断参数白名单补齐三个新增值参数，仍由 PerformanceOptions 严格校验 |
| `8ee2df0` | 可见性恢复时用上次采样帧数建立基线，保留采样前已经呈现的唯一帧 |

F1 的呈现预期检查 owning window、hidden ancestor、miniaturized、occlusion visible 与 render active；不依赖 `NSApp.isActive`。无呈现预期时，只有 finite 且真实推进的媒体时间算健康，真实网络停滞仍按原期限终止。重新可见时必须出现相对恢复基线的新帧，此后静止封面不需要每秒新帧。Core tests 覆盖条件组合、隐藏期间新会话、恢复无新帧继续等待，以及隐藏中的真实 stall。

额外本地单帧素材由 ffprobe 确认 video `nb_frames=1`，配连续 60 秒 AAC。旧 `82a9f19` 包在 healthy origin、200,000,000 bit/s 下，首个可见采样前帧数已从 1 到 4，随后保持 4；旧逻辑吞掉该首帧，17 秒出现错误重试，28.023 秒误 terminal，当时媒体仍在 27.622 秒、缓冲 32.128 秒。修后同素材、同速率 45 秒通过：首帧 1.031 秒，帧数仍保持 4，媒体到 44.775 秒，stalls/recovery_attempts/terminal/error 全为 0。先前普通速率单帧测试有首 tick 后额外重绘，不能单独证伪此边界；原日志均保留。

F2 将自动备选限制统一为 `stallRecovery && manualHost == nil`；用户显式选择节点仍可用，关闭恢复不禁用原有初始自动选优或多源功能。受限 direct 刷新分别保持视频、音频各自的 HTTP(S) authority（host 加有效 port），同 host 不同 port 也算其他节点；只允许当前节点的新签名，不能回退到其他签发备选。await 完成后重读 policy，取消过期候选与自动探测。Relay 保留原始源列表供解除 manual 后恢复使用，但 origins/pick/launch 在实际发请求前过滤；解除或停用当前 manual 同步解除 Relay 限制。已发出的旧请求与限制生效后的新请求区分，未声称能撤回已发流量。节点判据、取消、解除限制与不可重写签名源由离线/fake fetcher tests 覆盖；下面实际受限播放使用 direct 路由。

F3 同时要求 policy/Player terminal、固定错误、buffering=0、Relay connections/inflight=0、真实 mpv idle=1、原始引擎/媒体/渲染无推进、本地 origin active=0。终态前异步收尾允许持续多个样本，预算取首次全部 quiet 的 `max(App elapsed, origin observed elapsed)`；之后任何状态复活、推进、新连接或累计请求/字节变化均失败，并至少再观察一个后继样本。unknown 证据不能通过。非 terminal 的 `terminal_elapsed_s=nan` 表示时间不可用，不参与期限统计；所有实际 terminal 时间已核查 finite 且稳定。

### 同一最终包：5 项定向与原 28 轮

| 定向 case | 观察 | 结果 |
| --- | --- | --- |
| 高速单帧 healthy | 45 秒，固定帧数 4、持续媒体推进、无 retry/terminal | PASS |
| hidden35 | slow-start 0→3 秒，观察 45 秒，首帧 36.251 秒；隐藏媒体跨度 29.6 秒 | PASS |
| hidden50/reload4 | 同故障，观察 60 秒，隐藏中换新会话，首帧 51.931 秒；隐藏媒体跨度 43.7 秒 | PASS |
| direct manual | stall 5→90 秒，观察 60 秒；same-with-backup 刷新 1、reload 1，其他 port 请求 0；故障后 42.455 秒完全收敛 | PASS |
| direct no-switch | 同上，其他 port 请求 0；故障后 42.282 秒完全收敛 | PASS |

两个隐藏 case 在隐藏末 10 次采样均持续媒体推进。它们只抑制本次诊断 fixture 自己的呈现，没有操作用户最小化、遮挡、小窗或全屏；真实多窗口条件由 Core predicate 与迁移后 owning surface 调用链覆盖，不宣称实际窗口交互实测。

原 `--extended` 计划保持 28 轮不变，使用上述同一最终包串行运行，**28/28 PASS，suite exit 0**，无并行构建或编码。全部 App exit 0、无 watchdog 超时，最终上游 active=0、credential header 计数 0，显式 drain 后旧 Player/Surface/video layer 为 0；对象归零不证明底层内存全部回收。三个 profiling case 仍排除 CPU 比较，本轮不新增性能收益结论。

| 预期终止 case | 故障后首次全部 quiet（秒） | 预算（秒） |
| --- | ---: | ---: |
| persistent-stall-before-reference | 29.847 | 30 |
| persistent-stall-after-reference | 29.871 | 30 |
| persistent-403 | 29.774 | 30 |
| persistent-410 | 29.857 | 30 |
| midstream-persistent-stall | 43.237 | 50 |
| relay-403-refresh-same | 29.839 | 30 |
| relay-403-refresh-cancel | 29.754 | 30 |

这 7 项加两个受限 direct 定向共 9 项，首次 quiet 后所有采样的累计 requests/bytes 恒定，runner 最终 origin snapshot 的 primary+backup 累计值与首 quiet 完全相等，最终 active=0；覆盖最后采样至进程退出的尾段，没有仅凭 UI 时钟停止判断收敛。

```sh
python3 scripts/network_stability_suite.py --app .build/task-b-v3/final-v3/满屏.app \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 --bitrate 8158613 \
  --output .build/<NEW_DIR> --extended
```

证据：`.build/task-b-v3/network-final-v3/summary.json`、`targeted-v3/summary.json`、`static-frame-fast-final/summary.json`、`terminal-tail-check-v3.json`、`bundle-v3-gates/provenance.json`；每项定向命令与脱敏日志均在对应目录。

中途失败没有计入最终成功轮次：初版 `final/` 首 target 2.512 秒 exit 0，但无 PERF、无 HTTP、diagnostic_complete=false；确认为 Application 外层白名单遗漏，`82a9f19` 修复后才真正实播。`final-v2/` 的四定向和旧 28 PASS 保留为旧版历史，随后高速单帧反例暴露 F1 误终止，不能充当最终交付证据；最终结果来自 `8ee2df0` 新包的完整重跑。一次临时汇总脚本误匹配 hidden 文件名导致停止，只修正汇总读取后继续，已通过的实播未重复运行。

最终代码的干净源码 pre/post：`swift build --disable-automatic-resolution --skip-update`、`swift test` 均通过，548 tests / 5 skipped / 0 failures；privacy 0 findings；Python 终态判据 12 tests 通过。5 个 skip 保持原有环境边界。未使用真实账号或钥匙串，未运行实网匿名、真实代理/TLS/DNS 故障、用户窗口交互、4K/HDR/硬件切换或长循环内存复测；这些能力不因本地矩阵通过而被宣称验证。正式包未改、未 push。

## 0.1 发布包实网匿名播放（2026-10-19）

用 `dist/release/满屏.app`（0.1）通过 `scripts/anonymous_playback_check.py` 在真实网络上匿名播放。不读钥匙串，只发审计过的公开 GET 请求，也不启动聊天、心跳或进度上报。

| 项目 | 首帧 | 卡顿 | CPU 均值 / p95 | 内存（RSS） | 审计 |
|---|---|---|---|---|---|
| 公开视频 BV1czJB6fErF，330 秒 | 1.0 秒 | 0 | 12.7% / 17.5% | 最高 348 MiB | 凭据 0、非 GET 0、拒绝 0 |
| 推荐直播间（自动选择），330 秒 | 3.0 秒 | 0 | 12.7% / 15.8% | 最高 217 MiB | 凭据 0、非 GET 0、拒绝 0 |

两项的音频输出都是 CoreAudio，结果均为 PASS。

之前两次运行失败，原因都在测试工具：
- `finger/spi` 返回的 buvid4 末尾带 base64 填充符 `==`，GET 白名单不允许 Cookie 值里有 `=`，于是拒绝了后续请求。已修复，见 d6ea3d2。现在被拒绝时只记录类别和字段名，不记录值。
- 第一次选用的视频比 330 秒短。

本机装有防火墙时，第一次运行需要先放行 App 联网。

### 公开 UP 主空间与用户搜索（2026-10-19 匿名查证）

| 能力 | 路由 | 实际能力与处理 |
| --- | --- | --- |
| 完整投稿 | `/x/space/wbi/arc/search` | WBI、设备 Cookie、`web_location=1550101` 与 `dm_img_*`；支持 pubdate/click/stow、tid 和 tlist。匿名实测 -352/HTTP 412，只有这两类错误触发备用接口。 |
| 备用投稿 | App `/x/v2/space/archive/cursor` | App 签名，无 token 要求；`vmid/order/ps/aid`，末项 `param` 为下一页 aid；仅 pubdate/click，无 tid。返回 count/item/has_next，条目使用 title/cover/param/author/length/play。 |
| 投稿关键词 | gRPC `Space/SearchArchive` | 复用 `LibraryRPCService.userVideos`；仅最新顺序，无分区能力。 |
| 资料与主页 | `card?photo=true`、`upstat`、`top/arc`、`masterpiece`、`navnum` | `card.Official` 为认证，`space.l_img` 为头图；follower/like_num/archive_count 为可选统计。匿名 upstat 空对象时隐藏播放。无置顶 -404 视为空。 |
| 合集和系列 | `seasons_series_list` | 匿名可用，`items_lists` 内含 page/seasons_list/series_list；kind 与 ID 共同标识列表。 |
| 合集明细 | Web `seasons_archives_list` | 匿名，无 App token；page_num/page_size，`sort_reverse=true/false` 由服务端完成倒序。 |
| 系列明细 | `/x/series/archives` | 匿名，pn/ps、sort=asc/desc；不在本地翻转当前页。 |
| 用户搜索 | WBI `search/type?search_type=bili_user` | 独立 order=0/fans/level、order_sort；解析顶层 level/is_upuser/official_verify/is_live/room_id/upic。视频作者优先 owner/upper，再回退顶层 mid/upic。 |

投稿 cursor 绑定完整请求条件与 provider。WBI 在翻页时遇风控会重新从 app 第一页读取，并通知页面替换列表；界面展示实际顺序和分区能力。备用选择仅保留在同一个查询的 120 秒冷却期内，重试完整列表和账号切换会清除。取消、身份、认证与解析错误不作为降级依据。全部播放使用可注入的 cursor 分页收集器，去重、限制 1000 条、防游标循环；后页失败保留已读部分，用户明确点击后才播放。

## Live interaction contracts

Live routes and anonymous diagnostics are documented in [LiveContracts.md](LiveContracts.md).
`python3 scripts/live_readonly_check.py --dry-run` inspects the separate fixed GET allowlist.
No login data is loaded and no mutation is sent by this diagnostic.


### Live UI capability boundary (Unit 3)

| 能力 | 数据来源与展示 | 生产写入状态 |
|---|---|---|
| 富弹幕、礼物聚合、上舰、SC | 现有 WebSocket 解码与有界历史；服务端 ID 回复，实际 total_coin 价值 | 展示可用；不把广播当付款凭据 |
| 发弹幕、表情、回复、样式 | 共享 Core session；身份／房间／草稿 revision 核对 | 全部 `LiveMutationGate` 默认关闭 |
| 点赞、勋章佩戴／摘下 | 通过 actor 的手动操作；点赞沿用 Core debounce | 默认关闭，明确显示暂未开放 |
| 背包／电池送礼 | 整数报价、一次性确认、原交易待核对记录 | 默认关闭；固定价格白名单与 receipt policy 为空 |
| 免费抽奖／红包 | 仅 fixture 可注入已知条件与副作用并验证 synthetic receipt | 生产条件未知，只提供官方房间链接 |
| 充值／上舰／SC／消费记录 | 手动打开官方房间或直播个人中心，并提示在页面内选择对应功能 | 不构造未核实的深链接，不自动操作 |

设置只控制展示与用户付费偏好，不会打开任何写接口。纯享模式在特效入队前丢弃，屏蔽送礼同步隐藏按钮、礼物聊天与礼物特效。Unit 3 未执行实网核对、登录、真实账号写入、App 启动或截图；离线场景与交接见 [LiveUIHandoff](LiveUIHandoff.md)。
