# 开发者文档

原生 Apple Silicon 应用，目标 macOS 27。界面和业务以 BiliCopilot `896a06290ba440cb17776d292dff119bbd3383d6` 为基准，BiliKernel 协议基准为 `22fdf8ca04bab384b46536b05f6524a41f83a2d4`。页面验收见 [docs/Parity.md](docs/Parity.md)，性能结果见 [docs/Performance.md](docs/Performance.md)，未达项和使用者复验清单见 [docs/KnownIssues.md](docs/KnownIssues.md)，交接记录见 [Ledger.md](Ledger.md)。

## 环境与源码构建

需要 Apple Silicon Mac、macOS 27、完整 Xcode 27、Python 3 和 Homebrew。Swift targets 使用 Swift 6 严格并发模式。不需要改动全局 `xcode-select`；所有命令显式指定当前构建使用的 Xcode。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift package resolve
swift build
swift test
```

`Package.resolved` 固定 Swift/gRPC/Protobuf/NIO 依赖版本。首次构建需要下载这些公开依赖；测试默认只使用 fixture 和本地 loopback，不读取真实登录凭据、不执行账号写操作、不调用付费 AI。两个显式实网测试默认跳过。

业务代码在 `Sources/ManpingCore`，原生 AppKit/SwiftUI 页面在 `Sources/ManpingApp`，固定协议生成代码在 `Sources/BiliProtocol`。网络与身份由 `BiliService` actor 管理，UI 在 MainActor，mpv 命令、视频渲染和外部 IPC 各有独立队列。

## 开发运行与离线截图

仅运行源码时需要 libmpv；下载合并另需 FFmpeg。开发环境可以安装这些工具：

```sh
brew install mpv ffmpeg pkg-config ninja
swift run Manping
```

libmpv 通过 `dlopen` 加载，开发默认 `/opt/homebrew/lib/libmpv.2.dylib`，可用 `MANPING_MPV_LIBRARY` 指定路径；正式包优先加载自己的 `Contents/Frameworks/libmpv.2.dylib`。系统通知需从 `.app` 包运行。自定义外部 mpv/libmpv/画质 profile 在重新打开播放器后生效。

Debug app 复用 `dist/release/满屏.app` 的运行时（先用 `python3 scripts/bundle.py` 生成），不重新编译 renderer：

```sh
python3 scripts/build_debug_app.py
scripts/live_check.sh --fixture --theme dark --wait 4 \
  --pages popular,settings,article:cv100 --video BV1xx411c7mD --pgc ep837204 \
  --output docs/screenshots/local-fixture
```

fixture 使用隔离身份、合成封面与业务响应，不读取 Keychain、不加载在线媒体、不发送真实账号写操作。Debug 支持 `--ui-page`、`--ui-theme`、`--ui-window-size`、`--ui-video-tab`；截图通过窗口 PID/尺寸和登录面板状态校验。生产外部 mpv IPC 的本地检查命令：

```sh
.build/out/Products/Debug/Manping --ui-fixture \
  --ui-runtime-checks scripts/fixtures/mock_mpv.py
```

## 构建自包含 Release 包

`dist/` 下仅允许写 `dist/release/`，其它目录全部只读。首次打包默认拒绝覆盖已有输出；重打包使用显式的 `--replace-release`：先在 `.build/release-stage/` 构建并验证，再替换 `dist/release/`，旧 Release 保留在 `.build/release-backups/`。

首次从干净源码创建固定 libmpv 时：

```sh
python3 scripts/build_mpv.py
python3 scripts/bundle.py --verify-inputs
python3 scripts/bundle.py --output dist/release/满屏.app
open dist/release/满屏.app
```

已有 Release 时重新打包与只读校验：

```sh
python3 scripts/bundle.py --replace-release
python3 scripts/verify_bundle.py --static-only
```

`build_mpv.py` 只在项目 `.build/` 内建立 Meson 环境、下载校验固定 mpv 0.41.0 源码、应用锁定补丁并构建 arm64 libmpv，不安装或覆盖 Homebrew。现有 shader 资源已经入库，常规产品构建无需重新生成。构建输入和许可证由 `Dependencies.lock.json`、`MpvBuild.json` 与 `ThirdPartyNotices/` 记录。

若在另一台机器上 Homebrew 依赖的实际 SHA 或绝对源路径与锁文件不同，`--verify-inputs` 会明确失败。核对依赖版本和来源后，可显式运行 `python3 scripts/bundle.py --update-lock --verify-inputs` 记录该机器的输入；不要把校验失败当作成功。

打包脚本在独立 `.build/release-bundle/` scratch 目录运行 `swift build -c release --arch arm64`，避免与 Debug 共用 Xcode 构建数据库；可用 `--scratch-path` 指定另一项目内目录。脚本递归收集 libmpv/FFmpeg 动态库闭包、检查 arm64、重写 install name/RPATH、复制 CA 根证书与许可证，然后按现有方式逐库及 `.app` ad-hoc 签名，最后 `codesign --verify --deep --strict`。包内不依赖 Homebrew 运行路径。HTTPS 保持 ATS/TLS 验证，封面 HTTP 地址统一升级 HTTPS；不放宽 ATS。`dist/release/BundleManifest.json` 记录最终签名后二进制哈希。

## 登录与同一构建的实网验收

登录支持扫码与网页 Cookie，账号凭据存于 Keychain。退出/换号会清理该账号状态并取消在途请求；生成的下载命令不含凭据。账号写操作只在用户主动操作时发送，开发验收仅测试 fixture。

每次 ad-hoc 构建签名变化，防火墙软件和钥匙串可能需要重新授权。不要绕过系统弹窗；等使用者在场时只构建、签名一次，再集中运行只读验收：

```sh
python3 scripts/build_debug_app.py
scripts/live_check.sh --wait 60 --video BV1xx411c7mD --pgc ep837204
```

脚本复用同一个 `.build/ui/满屏 Debug.app`，不重新构建/签名；实网截图包含头像、昵称等个人信息，只允许保存到 `.build/live-private/`，禁止提交。可用 `--pages` 限定待复验页面；专栏用公开 `article:cv<ID>`。截图成功仍须逐页确认数据、空状态与报错，不能代替功能验收。

## AI 与最终验收边界

AI 配置按原版注册的 22 个 provider 和各协议族实现，API key、附加 secret 只存于 Keychain，非秘密配置保存为 `ChatClientConfiguration.json`。设置页和播放/阅读页入口以 Parity 实际状态为准。协议验证只允许 fixture 或本地 mock server，不在开发过程中发起付费调用。

### 用 ChatGPT 套餐（Sign in with ChatGPT）

设置 → AI 服务 → 「ChatGPT 套餐」卡片 → **Continue with ChatGPT**。按 OpenAI 面向开源／本地应用的官方流程（[文档](https://developers.openai.com/siwc/token-sharing-open-source)）：首次登录动态注册本应用（`dynamic_agent_client` → 签发的 `oaiapp_…`），浏览器授权后回到 `http://127.0.0.1:<端口>/auth/callback`，PKCE + RS256 ID token 校验，必须授予 `chatgpt.tokens.use.direct`。令牌只存 Keychain（`io.github.pidean.manping.ai.chatgpt.v1`），刷新令牌轮换且单飞刷新；推理走公开 Responses API（`store:false`、`stream:true`），用量计入 ChatGPT Plus／Pro 套餐，额度用尽时提示「Manage usage」而不会改走其它计费渠道。退出登录会撤销刷新令牌。

### Claude

Anthropic 条款只允许 Claude 订阅（Free／Pro／Max）用于 Claude.ai 与 Claude Code，第三方应用使用订阅 OAuth 令牌属于违规（[说明](https://code.claude.com/docs/en/legal-and-compliance)），因此本应用只支持 Anthropic API key（[console.anthropic.com](https://console.anthropic.com)，按量计费）。预置 Claude Opus 5.5（默认）、Sonnet 5.5、Haiku 5.5、Fable 5.1；这些模型使用 adaptive thinking，总结/评价用 `low`、问答用 `medium` effort，在官方端点上默认开启服务端拒答回退（`fallbacks: "default"`），拒答会给出明确提示。

renderer/shader/mpv 渲染算法和画质保持冻结；允许修复已定位的生命周期资源释放。实际字幕/章节、独立窗口切换、外部工具、系统媒体键、通知授权和磁盘下载仍需在使用者在场时集中复验；物理 HDR/外屏、睡眠恢复和长期运行的未验范围见 KnownIssues。

## Release 离线性能复验

正常桌面会话中运行以下命令，先完成全部构建，不同时编码素材、编译或运行其它播放器：

```sh
python3 scripts/performance_check.py --generate-media
```

脚本使用包内 FFmpeg 生成 `.build/perf-media/` 下的两份60秒4K60测试片，随后串行测推荐/热门/搜索600项滚动、H.264/HEVC播放、50次真实播放器开关和200次页面切换，最后与本机独立 mpv 对比（未安装时明确跳过）。原始文本和 CPU/RSS CSV 仅保存在 `.build/performance/`，不生成大型 evidence JSON。GPU/能耗不测，不运行 sudo/powermetrics。

长循环内存复验（先完成 Release 构建及素材生成，运行时不同时编译）：

```sh
python3 scripts/memory_check.py --output .build/memory-300
```

该入口隔离身份，完成300次本地播放器创建/渲染/关闭，每25次在播放器关闭状态执行 `vmmap --summary`，最终执行 `leaks`。文本只保存在 `.build/`；不读取真实登录、不访问网络、不提权。

确定性分配差分使用 `python3 scripts/memory_check.py --iterations 150 --stack-graphs --output .build/mem-diff`。脚本仅对子进程设置 `MallocStackLogging=1`，在关闭态等待ACK后保存第25/150次memgraph和heap；graph只留 `.build/`，不提交，分类字节和栈结论见 Performance。

Release 中的开发诊断入口必须显式启用隔离 fixture：

```sh
dist/release/满屏.app/Contents/MacOS/Manping --perf-fixture --perf-scroll popular
dist/release/满屏.app/Contents/MacOS/Manping --perf-fixture --perf-play-local .build/perf-media/testsrc2-hevc-4k60.mp4
dist/release/满屏.app/Contents/MacOS/Manping --perf-fixture --perf-stability --perf-media .build/perf-media/testsrc2-h264-4k60.mp4
```

诊断使用独立设置、模拟身份和传输，不访问真实 Keychain 或在线媒体；本地播放仍走实际内嵌播放器和 Surface。滚动统计 NSView displayLink 的实际到达间隔；播放掉帧只计算5秒预热后的计数差，阈值保持 `<0.1%`。最终数值和测量限制以 Performance 文档为准。

## 来源与许可

[ThirdPartyNotices/README.md](ThirdPartyNotices/README.md) 和 `Dependencies.lock.json` 记录依赖来源。项目基于 GPL-3.0 上游，shader 和 SDK 保留各自许可。ad-hoc 签名用于个人本机运行，不等同 Developer ID 或公证；对外分发时必须一并提供本项目、对应依赖源码、构建说明和实际许可证。
