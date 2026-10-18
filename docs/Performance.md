# M9 性能验收

2026-10-14，M1 Max（10 CPU／32 GPU／64GiB），macOS 27.0.1，Release／arm64。窗口1280×850pt、backing scale 2，显示器120Hz；滚动 displayLink 请求60Hz。测试串行运行，无同时编译或编码。M9 原验收包主程序与滚动候选的 SHA-256 均为 `fe11778cf0f4c055e3a2e8121512fc9e94f2562aab9b1d0f847cc48c155ff2d7`。

## 列表

真实推荐、热门、搜索网格，各600个唯一 fixture 条目，共用8张512×288合成封面缓存位图；不覆盖500张独立图片的冷解码或实网翻页。预热2秒后以2400pt/s往返滚动30秒；实际位移约0–59720pt，几何更新至少1798次且均确认往返。统计的是 [NSView displayLink](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)) 回调实际到达间隔，不等同 GPU 完成或物理呈现时间。

| 页面 | p50 ms | p95 ms | p99 ms | >25ms占比 | CPU均／峰 % | 判断 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 推荐 | 16.667 | 16.704 | 18.545 | 0.0000 | 25.51／86.60 | 本轮60Hz节奏通过 |
| 热门 | 16.667 | 16.702 | 20.651 | 0.0556（1/1800） | 25.85／87.30 | 接近60Hz，仍有1次慢回调；保留未严格稳定的结果 |
| 搜索 | 16.666 | 16.702 | 18.235 | 0.0000 | 26.02／85.50 | 本轮60Hz节奏通过 |

首轮 >25ms 占比分别为1.1204%／0.6138%／1.9729%。独立 `sample` 诊断轮显示主线程开销集中在 SwiftUI 布局、AttributeGraph 更新，并包含合成封面的布局。修正了测试额外开销：合成封面一次栅格化并复用，贴近生产缓存位图路径；直接驱动 NSClipView，避免每帧写 ScrollPosition 带来的额外视图事务。保留真实卡片、LazyVGrid、数量、速度及阈值；renderer未改。诊断采样轮不计入上表，修正后仍存在的热门慢回调不剔除。

2026-10-17 视觉统一后，在同一台机器上同日对照（120Hz 屏、60Hz 节奏）：
- 改造前 HEAD：p95 为 21.1／23.1／23.0 ms，>25ms 占比 0.11／0.06／1.18%。
- 改造后：p95 为 21.2／23.9／21.1 ms，>25ms 占比 0.11／1.17／0.11%。

两者在噪声范围内持平。当天的基线比上表更高，属于环境差异，不表示改造带来回退。改造过程中发现两点：
- 给整块内容面板加 `.shadow` 会让超时帧升到约 7–8%。阴影已改为挂在静态背景上。
- 卡片的悬停阴影也改为只在悬停时挂载。

## 4K60 播放

使用包内 FFmpeg 9.0.2 生成两份60秒 `testsrc2 3840×2160@60 + sine 48kHz/AAC`，H.264 High 35Mbps／HEVC Main 25Mbps，均为8-bit YUV420。素材仅 `.build/perf-media/`。实际内嵌 Surface 播放，音量0保留音频解码和时钟，弹幕关闭，默认 high-quality／VideoToolbox。预热5秒后取计数差，分母为 CFR60 × 实际媒体推进；确认渲染帧推进。

| 播放器／素材 | 观测帧数约 | VO掉帧 | decoder掉帧 | 合计掉帧率 | hwdec-current／estimated-vf-fps | CPU均／峰 % | <0.1% |
| --- | ---: | ---: | ---: | ---: | --- | ---: | --- |
| App H.264 | 3297.0 | 0 | 0 | 0.000000% | videotoolbox／60.000 | 21.14／42.00 | ✅ |
| App HEVC | 3295.0 | 0 | 0 | 0.000000% | videotoolbox／60.000 | 21.89／85.20 | ✅ |
| 独立 mpv H.264 | 3286.1 | 0 | 0 | 0.000000% | videotoolbox／60.0 | 24.00／35.80 | ✅ |
| 独立 mpv HEVC | 3287.1 | 0 | 0 | 0.000000% | videotoolbox／60.0 | 24.86／37.00 | ✅ |

独立 mpv 0.41.0 使用相同素材、profile、硬解、音量、音频同步及缓存设置，窗口请求847×651pt。App为libmpv/OpenGL（FBO1694×1302），独立版为gpu-next/macvk（IPC报告OSD848×652）；输出后端和尺寸口径不同，不作为等像素GPU或能效比较。两者均是4K源解码，未证明原生4K输出渲染。掉帧属性按 [mpv 0.41.0 固定文档](https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/DOCS/man/input.rst) 解释；估算fps不是分母。首次独立HEVC试跑与编译重叠，已排除，使用上述无并行编译的结果。


最终补缺Release（SHA前缀 `8d1f23a532e242aa`，同上面的300次修后候选）在全部构建完成后串行复测同一素材：

| 素材 | 预热后约帧数 | VO／decoder增量 | 掉帧率 | hwdec／估算fps | CPU均／峰 % |
| --- | ---: | --- | ---: | --- | ---: |
| H.264 | 3294 | 0／0 | 0.000000% | videotoolbox／60.000 | 25.46／44.90 |
| HEVC | 3296 | 0／0 | 0.000000% | videotoolbox／60.000 | 26.54／77.60 |

两者仍通过 `<0.1%` 目标；HEVC预热内VO计数为1，保留该观测，按既定规则只以5秒预热后的增量计算。文本/CSV在 `.build/performance-final-gaps/`；这次重测验证生命周期锁修点后播放无该指标回归，不重新声明滚动或物理显示验收。

## 生命周期与内存

M9 原验收 Release 完成50次实际播放器创建／渲染／关闭和200次页面切换，约107秒。每10次采样RSS；下表节选，完整逐10次文本留在 `.build/performance-refined/stability.log`。

| 播放起停次数 | 0（冷启动） | 10 | 20 | 30 | 40 | 50 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| RSS MiB | 99.250 | 288.531 | 295.094 | 302.016 | 323.922 | 327.344 |

| 切页次数 | 0 | 10 | 100 | 110 | 200 | 再闲置2秒 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| RSS MiB | 327.344 | 336.312 | 336.062 | 324.031 | 324.219 | 324.219 |

起停阶段RSS持续上升（第10→50次+38.813MiB），切页阶段稳定并回落。每10次及最终检查，旧Player／Surface／VideoLayer弱引用保留数均为0，当前引擎关闭；按设计排除最后一个仍被AppModel持有的已关闭Player。未发现这些Swift对象滞留，但不能据此排除底层分配问题。该轮driver／allocator缓存解释仅为推断；后续300次定位出浏览页自身引用环，见下一节。保留原始结果，不强制清理allocator或修改渲染算法。


## 300 次起停定位与修复

2026-10-14，沿用上面的机器、窗口、600项fixture和本地H.264 4K60素材。两轮均为Release，串行创建、确认媒体/渲染帧推进、关闭300个真实libmpv引擎；每25次在播放器关闭状态停5秒执行 `vmmap --summary`，最后闲置并执行 `leaks`，不提权。原始文本仅 `.build/memory-300/` 与 `.build/memory-300-fixed-stop/`，复现入口 `python3 scripts/memory_check.py`。采样工具和测试本身有开销；这是关闭状态的累计分配诊断，不代替连续播放能耗测量。

| 次数 | 修前 footprint MiB | 修前 DefaultMalloc 活跃 MiB | 修前 IOSurface 驻留 MiB | 修前 IOAccelerator graphics 驻留 MiB |
| --- | ---: | ---: | ---: | ---: |
| 25 | 242.4 | 40.5 | 5.531 | 25.4 |
| 50 | 205.2 | 50.5 | 5.531 | 15.1 |
| 100 | 204.5 | 70.5 | 5.531 | 23.5 |
| 150 | 227.6 | 90.2 | 5.531 | 26.6 |
| 200 | 240.3 | 110.3 | 5.531 | 18.5 |
| 250 | 258.0 | 130.3 | 5.531 | 20.4 |
| 300 | 277.2 | 150.4 | 5.531 | 20.4 |

修前 `leaks` 报15658个分配、41657024 bytes（39.727MiB），其中300个 `BrowseFeedModel` 根引用环：feed → loader closure → SwiftUI View/StateObject → feed。每次退出播放重新装载推荐页，600项列表被保留，DefaultMalloc活跃字节25→300近线性增加109.9MiB，尚未进入平台期。播放器、主Surface/VideoLayer弱引用为0并不能排除这个页面模型泄漏。修复为loader显式捕获参数/service，页面离开时取消并清空loader；重新进入仍可恢复分页和刷新。

另发现mpv 0.41原生剪贴板后端299个16-byte `Clipboard` 根泄漏（共4784 bytes）：该后端没有uninit。App剪贴板由NSPasteboard负责，默认mpv按键已禁用，因此初始化前清空 `clipboard-backends`，旧自定义lib不支持时忽略该可选设置。未改变渲染算法、画质、CGL/FBO分配或锁定mpv补丁。

修复后的第一次对照在25–50次区间停止推进，线程 `sample` 确证关闭主线程持gate等待CGL、CA渲染线程持CGL等待gate。该中断轮保存在 `.build/memory-300-fixed/`，不计作完成或平台期。统一timer/canDraw/draw/stop为CGL→gate，进入CA display前释放双锁；迟到回调看到engine=nil，资源释放顺序仍为render context→mpv handle，未改渲染算法。修点独立复核、build及285tests/2skip/0fail通过后重新运行完整300轮。

修前IOSurface驻留保持5.531MiB；IOAccelerator graphics未随循环线性增长，最终闲置后降至7.438MiB。增长主因有自身引用环证据，不能继续笼统归为GPU驱动缓存。



修后完整300轮耗时533.5秒、13次vmmap采样，主程序SHA-256 `8d1f23a532e242aa0c2971c7b71296ea8999399c58bd911fc3ec9a07313f58d7` 与本轮最终Release一致。无卡死；关闭状态旧Player/Surface/主VideoLayer弱引用均为0，当前可见BrowseFeedModel恒为1。

| 次数 | 修后 RSS MiB | 修后 footprint MiB | 修后 DefaultMalloc 活跃 MiB | 修后 IOSurface 驻留 MiB | 修后 IOAccelerator graphics 驻留 MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 25 | 296.500 | 219.4 | 36.9 | 5.531 | 15.0 |
| 50 | 310.453 | 234.9 | 43.2 | 5.531 | 17.5 |
| 100 | 326.609 | 248.5 | 56.1 | 5.531 | 16.1 |
| 150 | 346.516 | 233.9 | 68.4 | 5.531 | 24.1 |
| 200 | 358.594 | 202.7 | 81.0 | 5.531 | 16.4 |
| 250 | 371.359 | 218.0 | 93.7 | 5.531 | 30.8 |
| 300 | 389.516 | 219.0 | 106.2 | 5.531 | 28.2 |
| 闲置 | 389.203 | 198.1 | 106.1 | 5.531 | 7.563 |

修后 `leaks` 未再报告BrowseFeedModel/Clipboard根；仍报416个节点、19936 bytes（19.5KiB），三个根关联AppIntents `LNProcessInstanceRegistryClient` 的NSXPCConnection，不能归为防火墙软件。工具提示restricted-process，结果不证明所有底层泄漏均已排除。

最终 `heap -s` 仅1个BrowseFeedModel、1个当前已关闭PlayerModel，没有列出VideoLayer、VideoSurface、互动或评论模型实例；存在1374个AGX render pipeline、1367个GLR pipeline等驱动对象。但只有最终分类快照，另有59919319 bytes未分类non-object且无分配栈，**不能确认全部剩余增长是驱动缓存**。

结论：已确证的自身引用环和mpv剪贴板微漏已修，关闭锁反转已修并完成300轮；footprint及IOSurface驻留在这轮有界，RSS25→300仍+93.016MiB、DefaultMalloc活跃仍+69.3MiB，未进入平台期。**内存无持续增长目标仍未通过，剩余归因未完成**。本次定位从UTC18:03:34至18:52，约49分钟，在60分钟上限内结束；不根据猜测修改CGL或渲染算法。后续需分配调用栈或更长期同类别快照，不以footprint稳定替代RSS/活跃分配结论。


CPU由 `ps` 每0.5秒采样，100%表示一个逻辑CPU；App表格均值包含启动，独立mpv均值只含预热后，不能直接据此比较效率。生命周期CPU均30.04%、峰82.80%，RSS峰337.27MiB。GPU／能耗：**未测**，未运行 sudo／powermetrics。HDR、外屏、睡眠及整夜运行未测。

结论：本轮两种4K60实解码达到掉帧目标，推荐／搜索滚动通过本轮60Hz节奏；热门的单次慢回调和播放器循环RSS/活跃分配残余增长仍保留未达项；300次已定位并修复自身browse引用环、Clipboard微漏及关闭死锁。有限测试不代替物理显示和长期验收，见 [KnownIssues.md](KnownIssues.md)。复现：`python3 scripts/performance_check.py --generate-media`；原始文本／CSV仅在 `.build/`，没有新增性能 evidence JSON。

## 45分钟确定性分配差分（2026-10-14）

同一Release、H.264本地素材与1280×850窗口，以 `MallocStackLogging=1` 完成150次实际起停；25/150次关闭后等待采集器ACK，用 `leaks --readonlyContent --outputGraph=...` 保存 `.build/mem-diff/c25.memgraph`、`c150.memgraph`。两图可被heap/malloc_history读取，未修改签名或entitlement。该系统的stack logging默认lite，不能加fullStackHistory；实际分配转到MallocStackLoggingLiteZone，不能把DefaultMallocZone的变化当作产品改善。

`heap -s --diffFrom=c25.memgraph c150.memgraph` 显示新增且仍存活的分配；下表为两个完整 `heap -s` 的**净字节差**，同名类型的多行先求和，校验分类总字节分别等于原始header的45171644和79913020。净增34741376 bytes（33.131958MiB），第25→150次平均0.265056MiB/次。每类读取最大新增地址的完整创建栈，前两类另对全部1172个新增地址合并栈。

| 排名 | 增长类型（缩写） | 净增bytes | 净增MiB | 栈中的创建路径 |
| --- | --- | ---: | ---: | --- |
| 1 | malloc/dispatch_data_create | 9030400 | 8.612061 | Metal newFunctionWithGLIR ← GLDPipelineProgramRec.update |
| 2 | malloc/std::basic_string::__assign_external | 5900288 | 5.626953 | AGX Fragment/Vertex ProgramVariant 构造 |
| 3 | AGX::G13::VertexProgramVariant | 3000320 | 2.861328 | AGX创建vertex variant ← GLDDeviceRec pipeline lookup |
| 4 | AGX::G13::FragmentProgramVariant | 2400256 | 2.289062 | AGX创建fragment variant ← GLDDeviceRec pipeline lookup |
| 5 | malloc/AGX FragmentProgramVariantESLState | 2100224 | 2.002930 | AGX fragment variant ESL state构造 |
| 6 | AGXG13XFamilyRenderPipeline | 1800192 | 1.716797 | AGX newRenderPipelineState ← GLDDeviceRec |
| 7 | AGXG13XFamilyFragmentProgram | 1200128 | 1.144531 | AGX fragment program构造 |
| 8 | AGXG13XFamilyVertexProgram | 900096 | 0.858398 | AGX vertex program构造 |
| 9 | GLRRenderPipelineState | 900096 | 0.858398 | GLDDeviceRec.getRenderPipelineStateFromKey |
| 10 | malloc/MTLCompilerFSCache::getElementImpl | 758080 | 0.722961 | Metal MultiLevelCacheBase.getElement／compiler cache |

前十项合计27990080 bytes，占净增长80.57%。dispatch-data全部新增9030400 bytes均含newFunctionWithGLIR创建栈；C++ string全部新增5900288 bytes由AGX ProgramVariant构造（fragment5000192、vertex900096）。GLR和AGX render pipeline数量分别112→698、119→705，各+586；代表栈上游为App draw→libmpv→glDraw→AppleMetalOpenGLRenderer/AGX。这属于播放器触发的系统图形pipeline分配，不是本应用的日志/历史数组证据。

最大新增dispatch-data的反向持有链为MTLLibraryDataWithGLIR→_MTLFunctionInternal→GLRRenderPipelineKey.copy→CFDictionary键存储→GLDDeviceRec；支持图形驱动pipeline-key缓存字典持有这笔可达分配。该链是代表分配的证据，不证明每笔分配都是正常缓存或有上界。剩余19.43%含AppKit/SwiftUI等类型，未逐笔完成归因；不宣称所有底层泄漏均被排除。

heap中归属Manping二进制的具名类净增只有125个WeakPlaybackRecord、6000 bytes，是本次诊断有界弱引用记录；未见具名播放器/浏览/互动模型随起停增多。该分类不覆盖libswift泛型存储或剩余未逐笔归因分配，不能据此排除全部应用相关内存。

结论：主要增长已定位到系统OpenGL→Metal pipeline及缓存路径，未找到需要新增修复的应用容器/observer证据。按用户要求不硬改系统缓存，不改变renderer、shader、mpv配置或签名；本轮仅增强确定性诊断。无产品层修复，因此后续150次是同配置重复对照，不称“修后下降”。

同一Release再次完成150次同配置对照（两轮均MallocStackLogging=1、同素材与关闭态graph采样；没有产品改动）：

| 轮次 | 第25次全堆活跃bytes | 第150次全堆活跃bytes | 净增MiB | MiB/起停 | 是否下降 |
| --- | ---: | ---: | ---: | ---: | --- |
| 首轮 | 45171644 | 79913020 | 33.131958 | 0.265056 | 基准 |
| 重复对照 | 45515148 | 80827400 | 33.676388 | 0.269411 | 无明显下降 |

两轮分别255.8/259.6秒，150个实际引擎、7次关闭态vmmap及ACK全部完成，无卡死；旧播放对象为0、可见browse为1。Pipeline数首轮+586、对照+592，符合仍累积的观测，不证明正常缓存或平台期。**内存无持续增长目标仍未通过**。renderer/设置保持原样；系统缓存根因不做无依据的“清缓存”补丁。

原始graph/栈/类别净差TSV仅留 `.build/mem-diff/`，不提交。复现：`python3 scripts/memory_check.py --iterations 150 --stack-graphs --output .build/mem-diff`；heap class-pattern不外加^/$，例如 `heap -s --diffFrom=c25.memgraph --noContent --addresses='malloc in dispatch_data_create' c150.memgraph`，再用 `malloc_history c150.memgraph -fullStacks <address>`。本轮没有新增evidence JSON。

本轮 `swift build` / `swift test` 通过（285项、2跳过、0失败）；安全重打 `dist/release` 后46签名后哈希、arm64、依赖闭包、无Homebrew RPATH和strict codesign全部通过。最终主程序SHA-256 `7d4b0ba5368e8fdc4a93c537ba05616bb4b7ecbfdd2fccd50e251705b4b7c3d5` 与两次150测量包相同。本轮约27分钟完成，未超45分钟上限；未新增产品内存修补。


## 引擎复用（2026-10-17，f1085f3）

根因是每次播放都新建 VideoLayer（CGL context + mpv render context），GL program 每次重编译进系统 GLDDeviceRec pipeline 缓存。`MpvEnginePool` 保留一个已关闭的引擎和它的 render layer（`stop` 后重置 pause/speed），下一个播放器在库路径与画质 profile 相同时直接复用，90 秒未复用则释放。只改生命周期，渲染算法不变。

| Release，150 次起停 | 第 25 次 | 第 150 次 | 25→150 |
| --- | ---: | ---: | ---: |
| RSS MiB（复用前） | 296.5 | 346.5 | +50.0 |
| RSS MiB（复用后） | 305.3 | 323.2 | +17.9（100→150 仅 +2.9） |
| DefaultMalloc 已分配 MiB（复用后） | 60.3 | 64.8 | +4.5（复用前活跃 +31.5） |
| footprint MiB（复用后） | 450.2 | 423.5 | 无增长 |

149 次复用，每次都确认播放推进并渲染出帧。代价：停放期间保留视频尺寸的渲染缓冲，footprint 比不复用时高约 230MiB；`MANPING_MPV_POOL_IDLE_SECONDS=2` 的 50 次对照中，闲置后引擎被释放，footprint 回到 220.5MiB。复现：`python3 scripts/memory_check.py --app <Release app> --iterations 150 --output .build/memory-pool`。

## 弹幕运动流畅度（2026-10-18）

测量方法：调试报告里的 `dmMotion` 记录每一帧「媒体时钟前进 ÷ 两帧上屏时刻之差」，匀速时应恰为 1；同时统计帧率、帧间隔抖动、零前进帧和倒退次数。`dmRender` 记录渲染线程的单帧 CPU 耗时。测试屏幕为内建 Liquid Retina XDR（ProMotion，最高 120Hz），未登录实网播放。

| 场景 | 弹幕帧率 | 速度偏差 RMS | P95 | 零前进帧 / 秒 | 倒退 / 秒 | 最长帧间隔 |
| --- | --- | --- | --- | --- | --- | --- |
| 改前 · 番剧（约 24fps） | 46 | 24% | 32% | 6.4 | 0.17 | 93 ms |
| 改前 · 老 UGC（约 13fps） | 54 | 40% | 76% | 7.5 | 1.5 | 95 ms |
| 改后 · 番剧 | 120 | 0.8% | 0.8% | 0 | 0 | 8.4 ms |
| 改后 · 老 UGC（15fps，含一次 seek） | 119.3 | 1.2% | 1.3% | 0 | 0 | 16.7 ms |
| 改后 · 4K120 源（480P） | 120 | 0.1% | 0.2% | 0 | 0 | 8.3 ms |

根因与对策：
1. 位置用 mpv `time-pos`（按视频帧 PTS 量化）每 100 ms 硬写一次，取样时间戳又取自主线程收到消息的时刻 → 每次校正都是一次跳变，低帧率时会倒退。改为在轮询线程按同一时刻取 `audio-pts`（逐采样）喂给锁相环时钟：位置是一条直线，样本只微调斜率（±4%，约 1.5 s 收敛）；seek 显式重置并忽略迟到的旧样本；缓冲 / 卡顿时原地等待，不回跳。
2. MTKView 在主线程绘制，被 SwiftUI 抢占，只有 43–54 fps、偶发 70–135 ms 停顿。改为 CAMetalDisplayLink 驱动的独立渲染线程，按每帧上屏时刻取位置；帧率跟随显示器（最高刷新率，省电时 ≤60），暂停 / 关闭时 10 Hz 空转。
3. 每帧重算字形计划并为每个字形分配临时数组：2.37 ms/帧。改为只在弹幕集合变化时重新规划，每行布局缓存，顶点直接写入 GPU 缓冲：0.6 ms/帧（纯平移帧 0.44 ms）。
4. 新字形在帧内同步光栅化（含描边、阴影），出现时和 seek 后有 46–92 ms 尖峰。改为后台字形工坊提前 4 s 预渲染，新图集页不清零，旧页字形用 GPU blit 复制；还没就绪的弹幕晚几帧出现，渲染线程不等待：峰值 ≤5 ms，seek 时只丢 1 帧。
5. 滚动方向不再取整像素（原先每帧步长在 4 / 5 px 间交替）。

整体 CPU（含视频解码）从约 45% 降到约 28%，暂停时约 3%。直播开流头 2 秒时间戳不稳定时仍可能有短暂停顿，稳态与点播一致。
