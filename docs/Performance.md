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

## 任务 B：离线稳定性实测（2026-10-18）

环境：MacBookPro18,2 / M1 Max，10 CPU、64 GiB，macOS 27.0.1 (26A434)，Swift 6.4，arm64 Release，接通电源。源码 `a09c87c`，独立测试包 `.build/task-b/app/满屏.app`，主程序 SHA-256 `36e2f72e8d8401c0eb024645424071ea1b64cc343a07a63fa1527a20c9dd53dd`。使用 `MANPING_SIGN_IDENTITY=-` ad-hoc 签名，不查询钥匙串。原有 `dist/release/满屏.app` 未覆盖、未终止。诊断一律 fixture、隔离 UserDefaults、accessory、窗口不激活且鼠标点击穿透；未使用 `live_check.py`、`osascript`、sudo 或系统网络设置。

实际窗口 1638×850 pt、scale 2、120 Hz，App FBO 2460×1384；旧基线窗口 1280×850，输出尺寸不同。测试串行，编译与素材编码结束后才测量。CPU 的 100% 表示一个逻辑核；App CPU 均值包含启动，独立 mpv 只统计预热后，不能直接作为两种后端效率排名。

复现命令（`MODE` 分别取 `playback`、`stability`、`standalone`、`power`）：

```sh
MANPING_SIGN_IDENTITY=- python3 scripts/bundle.py --output .build/task-b/app/满屏.app
python3 scripts/performance_check.py --app .build/task-b/app/满屏.app \
  --only "$MODE" --media-dir .build/perf-media --generate-media \
  --output .build/task-b/local --power-label task-b --power-rounds 2
python3 scripts/memory_check.py --app .build/task-b/app/满屏.app \
  --iterations 75 --output .build/task-b/local/memory
```

构建命令只用于新的输出目录，不能覆盖已存在的测试包。完整命令与每项退出码见 `.build/task-b/local/runs.json`。沿用已有 60 秒 4K60 H.264/HEVC 素材；power 新生成 65 秒 1080p30 H.264/AAC，实测总码率 8,158,613 bps。

验收标准：4K60 预热 5 秒后 VO+decoder 丢帧率 `<0.1%`、VideoToolbox、实际渲染推进；生命周期完整完成且最终旧 Player/Surface 为 0。内存比较第 25→75 轮的增长与旧复用后 150 轮基线（RSS +17.9 MiB、活跃分配 +4.5 MiB），仅判断这轮幅度，不宣称长期平台期或零泄漏。power 没有旧同方法数值基线，只验收完整采集、硬解与掉帧，CPU/POWER 是观测量。

| 场景 | VO / decoder 丢帧 | 丢帧率 | CPU 均 / 峰 % | 结果 |
| --- | ---: | ---: | ---: | --- |
| App H.264 4K60，约3295帧 | 0 / 0 | 0% | 19.15 / 89.0 | 通过 |
| App HEVC 4K60，约3299帧 | 0 / 0 | 0% | 19.61 / 108.2 | 通过 |
| 独立 mpv H.264，约3285帧 | 1 / 0 | 0.030440% | 16.64 / 24.1 | 通过，保留1帧丢帧 |
| 独立 mpv HEVC，约3283帧 | 35 / 0 | 1.066098% | 15.50 / 25.6 | 未通过 |

App RSS 峰值分别 290.95 / 324.89 MiB。App CPU 均值低于旧基线 21.14/21.89% 及最终补缺轮 25.46/26.54%，但不是同日同尺寸 A/B，不计算优化百分比。独立 mpv 仍是 0.41.0、gpu-next/macvk、OSD 848×652，35 帧丢帧集中在媒体 30–37 秒，decoder 计数为 0；目前只能定位到输出端丢帧，不能从该轮断言 App 解码退化或给出更深根因。未修改外部 mpv 或渲染算法。

50 次实际播放会话起停、200 次切页在 85.6 秒完成，无卡死；第10/50轮 RSS 324.31 / 338.58 MiB，切页闲置后 326.95 MiB。CPU均/峰58.96/100.9%，高于旧轮30.04/82.8%，属于待归因信号：窗口、UI版本、复用和单位时间内起停速度均有差异，不能据此断言单一模块回归，也不能把CPU对照称为通过。最终旧 Player/Surface 为0，49次引擎复用。日志 `actual_engines=50` 是旧字段，实际代表会话数，不能解释成新建50个引擎；`retained_video_layers=50` 按弱引用记录逐条计数，同一复用 layer 被重复计数，不是50个独立对象。

| 75轮内存诊断 | 第25轮 | 第50轮 | 第75轮 | 最终闲置 |
| --- | ---: | ---: | ---: | ---: |
| RSS MiB | 331.984 | 332.047 | 340.578 | 339.109 |
| footprint MiB（工具标为M） | 502.5 | 501.8 | 504.2 | 473.5 |
| DefaultMalloc 活跃 MiB（工具标为M） | 68.6 | 69.2 | 69.9 | 67.6 |

75轮耗时89.8秒，74次复用，4个checkpoint加最终闲置共5次vmmap全部成功，旧Player/Surface最终为0、可见BrowseFeedModel为1。RSS25→75 +8.594MiB、活跃分配+1.3MiB，低于上述旧150轮增长幅度，但轮数和输出尺寸不同，不证明长期无增长。footprint绝对值比旧450MiB附近高，本轮更大的FBO与图形缓冲是差异因素，未做等尺寸归因，不能称该差值已解决。

`leaks` 成功执行并以退出码1报告 **420个分配 / 20,304 bytes（19.8KiB）**；这是“采集成功且发现泄漏”，不是零泄漏通过。3条NSXPCConnection循环包含AppIntents `LNProcessInstanceRegistryClient makeXPCConnection`，另有5个未分类80-byte根；没有BrowseFeedModel/Clipboard根。与旧416个/19,936bytes接近，仍保留未归因部分，未擅自修改AppIntents或系统图形缓存。原始脱敏文本在 `.build/task-b/local/memory/`。

| power：65秒1080p30，取5秒预热后约60秒，2轮均值 | 空弹幕层开启 | bursty（69条时间线） |
| --- | ---: | ---: |
| App CPU %（CPU-time / wall） | 11.47 | 16.89 |
| top POWER 均值（代理指标，非瓦数） | 11.29 | 16.68 |
| WindowServer CPU % | 30.05 | 46.14 |
| WindowServer 相对前10秒空闲差值 % | -11.69 | +5.20 |
| 弹幕提交 / 秒（含空白时段） | 0 | 104.93 |
| 4轮视频丢帧率 | 0% | 0% |

power完成并通过掉帧/硬解门禁。空弹幕没有持续提交；bursty存在实际Metal提交。WindowServer共享整个桌面，负差值说明背景活动变化较大，不能据此宣称节能百分比。未测物理GPU功率、温度或电池续航。报告 `.build/task-b/local/power-task-b.json`。

网络故障、持续首播等待修复、恢复时延及后续复测见 [Network.md](Network.md)。本轮新增 `diagnostic_privacy.py` 清理测量文本中的绝对路径、凭据头及relay能力URL；`performance_check.py` 补齐 `result=FAIL` 与独立mpv阈值退出门禁，并为独立mpv添加 `--focus-on=never --macos-app-activation-policy=accessory`。

### HEVC隔离复测与最终验证

全部构建结束后，独立mpv HEVC再测一次：约3285帧，VO/decoder增量0/0，0%丢帧，CPU均/峰22.50/30.30%，通过。首轮1.066098%的失败仍保留，当前未稳定复现，不能宣称根因已解决。随后用 `71124e7` 新包 `.build/task-b/app-fixed/满屏.app`（SHA-256 `2f0d1bfe6436b7042c27ade8331c74ee46901de412984428d1cfc8ddca807dab`）播放同一HEVC：约3299帧，实际render_frames_delta=3300，VO/decoder为0/0、0%丢帧、VideoToolbox，CPU均/峰24.83/92.0%，通过。日志/CSV在 `.build/task-b/recheck/`。

精确复测入口（串行，只取HEVC）：

```sh
python3 - <<'PY'
from pathlib import Path
import shutil, sys
sys.path.insert(0, 'scripts')
from performance_check import standalone, run_app
out = Path('.build/task-b/recheck').resolve()
out.mkdir(parents=True, exist_ok=True)
media = Path('.build/perf-media/testsrc2-hevc-4k60.mp4').resolve()
standalone(shutil.which('mpv'), media, 'hevc', out)
binary = Path('.build/task-b/app-fixed/满屏.app/Contents/MacOS/Manping').resolve()
run_app(binary, ['--perf-play-local', str(media)], 'playback-hevc', out, 110)
PY
```

修后 `swift test`：508项、5跳过、0失败（21.788秒）；修前505项、5跳过、0失败。新增3项为MediaRelay预算/慢源/取消回归。Python服务器9项和诊断2项通过；`python3 scripts/privacy_check.py` 为0 findings。构建有既有Swift/AppKit弃用和并发警告，不等于无warning。未发现独立lint配置，Swift编译与tests承担类型检查，另做Python语法及 `git diff --check`。性能、网络、泄漏的未达项不因单元测试通过而消失。

最终索引 `.build/task-b/verification.json`：20轮网络实验全部正常退出且无外部watchdog超时，其中17轮通过各自功能门禁，3轮持续故障未通过；119份测量文本扫描绝对路径和真实凭据值，0发现。仅扫描本次测量文本，不将已签名App当作日志修改。最初按要求执行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`，sandbox限制后使用正常构建权限重跑成功；两份独立Release包均通过strict签名验证。未登录、未读真实凭据、未动系统网络、未操作用户鼠标或窗口、未push。

计时：首个可核验UTC记录2026-10-18 13:28:14至最终扫描14:25:49，为57分35秒，包含后续构建、测试、复核和返工；此前环境检查未精确计时，因此这不是完整交付耗时的精确值。用户澄清等待0，人工纠正0；未以这一个任务样本声称角色配置最优或统计首次交付通过率。已发现缺陷与未达项保留在报告，没有用token或吞吐量替代交付结果。

## 任务 B 第二轮：音频饥饿 CPU 与诊断清理（2026-10-19）

环境仍为 MacBookPro18,2 / M1 Max，10 CPU、64 GiB，macOS 27.0.1 (26A434)，Swift 6.4、arm64 Release。最终独立包为 `.build/task-b-v2/final/满屏.app`，源码 `b38eb51`，主程序 SHA-256 `b102ea1881b264abd4fff4ba679e09ed2d097f23d28e9431913303b122178b68`；包内 libmpv SHA-256 `0dbc9892072183222e42b060e852a2e1047e2b47c8b3905d905b02805c0a3624`。ad-hoc 签名、App 隐私扫描、44 个库及 FFmpeg 输入闭包核对均通过。正式 Release 未覆盖、未终止；所有播放都是 quiet、无激活的独立进程。测试期间没有并行编译或编码。

### 同代码、仅替换 libmpv 的对照

前后包均使用 `05bc07b` 的应用代码；主程序编译输入 SHA-256 同为 `707e3f2eb9ccb16028eb7f18bdd65866635484b00b1f6bb6773efe53c11699bb`，仅 libmpv 输入变化，其他 43 个库与 FFmpeg 未变。包路径分别为 `.build/task-b-v2/audio-before/满屏.app` 与 `.build/task-b-v2/audio-after/满屏.app`，最终签名后主程序 SHA-256 分别为 `346aac0df9d5b7cc177f2ad0a83c82d5ed3645083b2bfc166fa23072d3c5a7fa`、`4ce138aba011fe268206792db06fce2ebcebaf6757597af25885945b98bb04b8`；资源 seal 变化会使签名哈希变化。

锁定的 mpv 0.41.0 在 `audio/out/ao_coreaudio.c` 将 `AudioChannelLayout` 传给了 `kAudioOutputUnitProperty_ChannelMap` / Global；本地 SDK 的该属性要求 `SInt32[]`、Input/Output scope。旧日志报 `-50`，随后默认输出回退 AVFoundation。新增 `patches/mpv-0.41.0-coreaudio-channel-layout.patch` 只把这两行改为 `kAudioUnitProperty_AudioChannelLayout` / Input，匹配原有输入 StreamFormat 与 bus 0；保留错误处理和后端 fallback。`12e56ab` 同步固定 patch SHA 与依赖锁，fresh-source 比较确认仅此两行语义变化。

判断标准：必须有实际非 null 音频输出及媒体推进；健康整轮 CPU 不超过前测的 1.2 倍，故障轮 CPU 至少下降 25%；恢复后有限、已知的 `|avsync|` p95 小于 100 ms。它们是本轮工程验收阈值，不是音质或物理显示精度标准。素材为同一份 65 秒 1080p30 H.264/AAC 合成文件，观察 60 秒，故障窗口 5–25 秒，参考码率固定 8,000,000 bps。音量 0 保留音频解码和输出。

| 场景 | 实际 AO 前→后 | 整轮 CPU % 前→后 | buffering 采样 CPU % 前→后 | `|avsync|` p95 ms 前→后 | 功能/音频门禁 |
| --- | --- | ---: | ---: | ---: | --- |
| 健康 | avfoundation→coreaudio | 15.85→13.06 | — | 1220.093→0.049 | 两轮通过 |
| stall | avfoundation→coreaudio | 44.79→15.13 | 105.770→18.262 | 1273.440→1.059 | 两轮自动恢复 |
| 限速 | avfoundation→coreaudio | 43.22→14.81 | 105.777→17.563 | 1120.085→0.507 | 两轮自动恢复 |

CPU 为 `ps` 每秒采样，100% 表示一个逻辑核。整轮包含启动和关闭，不能叫作纯卡顿 CPU；buffering 列只取与 App 标记对齐的样本，时间对齐误差约 1–1.5 秒。按源站故障时间划分的 CPU 均值，stall 为 109.700→17.290%，限速为 109.985→16.980%。健康稳态后段为 12.180→12.580%，没有把启动差异误称为稳态大幅下降。A/V 只统计有音频、推进中、未缓冲的有限已知值；缺值不填 0。健康后测 `|avsync|` 最大值 4.177 ms，stall 为 2.739 ms，限速为 1.796 ms。

两个对照反例保留：旧库强制 `--audio-driver coreaudio` 的 35 秒健康轮没有有效音频，虽然 CPU 为 13.33%，仍判 FAIL、排除优化比较；新库强制 `--audio-driver avfoundation` 的 60 秒 stall 轮功能通过，但整轮 CPU 45.34%、buffering 106.109%、A/V p95 1346.772 ms。该结果支持修正 CoreAudio 初始化，**没有修复 AVFoundation 本体的饥饿回调循环**。未修改生产 `audio-buffer`、`cache-pause`、`cache-pause-wait` 默认值。

另用包内 FFmpeg 从同一视频流生成 48kHz 立体声和 5.1 合成音轨，完成编码后串行观察各 45 秒：

| 输入 | CPU % 前→后 | AO 前→后 | 音频输入→输出声道 前／后 | A/V p95 ms 前→后 | 结果 |
| --- | ---: | --- | --- | ---: | --- |
| 立体声 | 16.79→13.43 | avfoundation→coreaudio | 2→2／2→2 | 1206.767→0.052 | 通过 |
| 5.1 | 17.35→14.19 | avfoundation→coreaudio | 6→6／6→2 | 1106.790→0.066 | 通过当前设备协商检查 |

未强制双声道；5.1 后测由 CoreAudio 按当前设备协商为两声道。没有耳听音质、实体 5.1 声道映射、AirPods、蓝牙、独占输出或热插拔实测。代码复核确认默认设备/UID、设备选择、hotplug 与 exclusive 分流均未修改；不能据此宣称硬件切换已通过。

完整 12 轮索引 `.build/task-b-v2/audio-comparison.json`，各轮 CSV/标量和阶段汇总在对应 `audio-before-*`、`audio-after-*`、`audio-channels/` 目录。以下单轮命令适用于包含媒体隔离证据的最终包：

```sh
python3 scripts/network_stability_check.py --app <APP> \
  --media .build/perf-media/testsrc2-h264-1080p30.mp4 \
  --output .build/<NEW_DIR> --origins single --scenarios stall --seconds 60
# 对照后端：额外传 --audio-driver avfoundation 或 --audio-driver coreaudio
# 仅诊断调参：--audio-buffer 0.1..2 / --cache-pause-wait 0.1..5
```

历史 A/B 使用 `05bc07b` 当时的 runner；这两个旧包不输出后来 `13eb526` 新增的媒体隔离证据，用当前严格 runner 直接复跑会判 FAIL，不能将其误判为播放退化。历史数字保留为存档；新的安全 A/B 应使用当前隔离代码分别构建两个库版本的包，不应为旧包放宽当前门禁或用于匿名实网。

### 044、010、108、110 的处理边界

- `044`：`862d289` 将 PGC tick 的整份 `MacSettings.load` 改为注入当前 AppModel 内存设置的弱引用 closure；应用内设置变化仍立即生效，没有把读取时机推迟到下一次播放。
- `010`：`f3a6d34` 将 Markdown/comment/inline 解析移入 View 自有、有界缓存，解析结果不保存 seek closure，当前交互闭包继续由 View 提供。三项单测验证相同文本 100 次访问只解析一次，文本、seekable、duration 变化会失效；单个 source slot 上限 512 KiB、inline 最多 256 项，不能解释为整个缓存 RSS 严格小于 512 KiB。没有调用真实 AI，也没有把 parser 单测当成流式 UI CPU 实测。
- `108`：`a197c74` 只在诊断模式读取 hwdec、性能/媒体属性、shader passes 与事件数组；正常时间/audio-pts 平滑时钟、cache/state/EOF 和 gamma/aspect 保留。此项通过引用与调用路径复核，没有单独给出正常模式 CPU 降幅。
- `110`：无人消费的 Shadowsocks Stats/byte counters/onEvent 整链删除；真实 health/probe/rebuild/onRebuilt 和同步机制保留。没有把回环直连结果推广为 Shadowsocks 性能结论。

本轮没有重跑长轮次 vmmap/leaks；上一轮记录的系统/框架残留和 RSS 增长没有因此被宣称解决。最终网络资源回落与 4K60 验收另见下述最终实测及 [Network.md](Network.md) 第二轮记录。

### 最终 4K60 复测（同一 b38eb51 最终包）

```sh
python3 scripts/performance_check.py --only playback \
  --app .build/task-b-v2/final/满屏.app --media-dir .build/perf-media \
  --output .build/task-b-v2/playback-final --generate-media
```

两份现有 60 秒素材未重新编码。窗口 1638×850 pt、scale 2、120Hz，实际 FBO 2460×1384，与上一轮任务 B 一致；是 4K 源解码验收，未证明原生 4K 输出或物理呈现时间。门禁仍为 5 秒预热后 VO+decoder 掉帧率 <0.1%、VideoToolbox、渲染推进。

| 素材 | 预热后 CFR 估计帧数 | 渲染帧增量 | VO/decoder 掉帧 | 掉帧率 | 硬解/fps | CPU 均/峰 % | RSS 峰 MiB | 结果 |
| --- | ---: | ---: | --- | ---: | --- | ---: | ---: | --- |
| h264 | 3299.0 | 3298 | 0/0 | 0.000000% | videotoolbox/60.000 | 20.64/104.8 | 253.80 | PASS |
| hevc | 3297.0 | 3296 | 0/0 | 0.000000% | videotoolbox/60.000 | 20.40/97.9 | 301.14 | PASS |

`performance_check` 退出 0，两轮均含 PERF complete、无 FAIL。CPU 取整轮 0.5 秒 ps 采样，掉帧只取预热后计数差。上一轮任务 B 相同窗口记录 CPU 19.15/19.61%，本轮为 20.64/20.40%，约高 7.8%/4.0%；源码及测量时刻不同，不能归因于单一补丁，也不据此声称正常播放 CPU 下降。相同代码的额外 H.264 对照用于核对此差异。

原始日志/CSV 与汇总 `.build/task-b-v2/playback-final/summary.json`。完整网络矩阵 28/28 的逐轮数字、资源限制、匿名实网失败尝试和清理保留项见 [Network.md](Network.md) 第二轮章节。

补充同代码 H.264 对照：使用上述 audio-before/audio-after 两包，相同应用编译输入、相同 4K60 本地素材和 FBO，先原库后候选库串行各一轮。两轮均 VideoToolbox、预热后 VO/decoder=0/0、result=PASS；整轮 CPU 20.009→19.909%，10–55 秒观察段 18.710→18.234%（各 88 个 ps 样本）。这组相邻对照未见正常 H.264 CPU 成本增加，不证明所有环境下必然下降。证据 `.build/task-b-v2/healthy-4k-control/summary.json`；调用现有 performance_check.run_app，参数为 `--perf-play-local .build/perf-media/testsrc2-h264-4k60.mp4`。

## 第三轮审查后的诊断证据（2026-10-19）

本轮修复呈现预期、节点限制与终态验收，未修改 renderer pacing、设备选择或 libmpv 输入。最终应用源码 `8ee2df0`，独立包 `.build/task-b-v3/final-v3/满屏.app`，主程序 SHA-256 `d326a50edaf437d0370a7efc18ff96f5367b50bf3677111131ce1f5aff280a60`，libmpv 仍为 `0dbc9892072183222e42b060e852a2e1047e2b47c8b3905d905b02805c0a3624`。包从干净 detached commit 构建；主工作区保留的外部 M8 未完成源码另行导致构建失败，没有进入该包。输入闭包、签名与 privacy gate 均通过，详情和限制见 [Network.md](Network.md) 第三轮。

原 `82a9f19` 包虽完成旧 28 轮，但新增的精确单帧反例在 28.023 秒误终止：首个可见 tick 前唯一内容帧已经呈现，旧进展判据却把它作为等待基线。最小修复改用前一次采样帧数，保留这段时间内的新帧证据。相同单帧视频加连续 AAC、本地 healthy 200 Mbps、45 秒重跑，帧数从首个 visible sample 起保持 4，媒体推进到 44.775 秒，无 stall、retry 或 terminal；静止画面不再依赖额外 layout 重绘维持健康。Core 回归同时保留恢复时无新帧必须等待的条件。

同一新包完成高速单帧 1 项、隐藏/隐藏中换会话 2 项、受限 direct 恢复 2 项，以及原 28 轮矩阵，合计 33 项通过，测试期间无并行 build/encode。隐藏仅操作本次 quiet fixture 的 view，不代表实际用户窗口最小化/小窗/全屏实测。终态计时取真实引擎和本地源站全部 quiet 的首次观察，不使用暂态 first_error；7 个矩阵终止 case 加两个 direct 定向，在首次 quiet 至最终 origin snapshot 请求/字节均恒定、active=0。

这组实验验证功能与停止收敛，不新增 CPU、掉帧、长期 RSS 或物理呈现性能结论。三个 profiling case 不进入 CPU 比较；旧 Player/Surface/layer 在 drain 后为 0，也不等同底层内存完全回收。本轮未重跑 4K60、vmmap/leaks 或长循环，前述历史结论与限制保留。逐样本、CPU CSV 和命令在 `.build/task-b-v3/`，最终索引为 `network-final-report-v3.json` 与 `implementation-report.json`。
