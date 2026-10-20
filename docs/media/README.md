# README 动图

`docs/images/*.gif` 全部来自调试版在**离线样本**（`--ui-fixture`）上的真实运行画面：界面、导航和数据流都是 App 自己的，但不登录任何账号，也不请求 B 站。样本里的标题、UP 主、弹幕和直播聊天是虚构的；弹幕和聊天写的是满屏的功能介绍。封面、头像和播放画面是 CC0 授权的实拍照片（见下文「素材」）。

| 动图 | 场景 | 内容 |
|---|---|---|
| `hero.gif` | `hero` | 首页网格 → 悬停卡片浮起 → 打开视频，弹幕滚动、玻璃控制面板 → 沿进度条悬停（章节分段、预览与「时间 · 章节名」）→ 停下 2.5 秒后控件淡出 |
| `danmaku.gif` | `danmaku` | 弹幕特写（推近）→ 弹幕设置：显示区域半屏 → 全屏、字号调大 → 关闭再打开弹幕 |
| `mini.gif` | `mini` | ⇧⌘P 打开小窗（右下角）→ 主窗口切到首页、专栏，播放不中断 → 悬停小窗出现玻璃控件 → 拖到左上角吸附 |
| `live.gif` | `live` | 直播网格 → 进入直播间 → 聊天与画面弹幕、醒目留言和礼物特效 → 在侧栏输入并发送弹幕 → 点赞 |
| `ai.gif` | `ai` | 视频页切到 AI → 点「章节总结」，回答出现 → 点回答里的时间点，画面跳过去 |
| `settings.gif` | `settings` | ⌘, 打开设置窗口 → 直播（纯享模式、特效开关）→ 网络 → 致谢 |

## 素材

`assets.json` 列出全部素材的出处、作者和许可；`fetch_assets.py` 把它们下载到 `.assets/`（不进仓库）。全部是 CC0 照片，大多是早年从 Unsplash 导入 Wikimedia Commons 的作品：

- **封面与头像**：24 张，按应用显示的尺寸下载（封面 1280 px，头像 400 px）。头像只用动物、植物和物件，不用人脸。
- **播放画面**：点播视频由 4 张山湖照片拼成，每张一个章节（70 秒）；直播是一张城市夜景照片（30 秒）。画面是静止的照片：实拍视频每一帧整幅都在变化，做成 GIF 每张有 30～55 MB；用照片时只有弹幕和界面在动，每张能控制在 5 MB 内。章节、进度条预览和跳转仍然照常工作。

下载走系统代理（Python 的 urllib）；ffmpeg 只处理本地文件。

## 怎么做出来的

1. **演示导演**（`Sources/ManpingApp/DemoDirector.swift`，只在 Debug 构建里存在）：`MANPING_DEMO_SCENE=<场景>` 加 `--ui-fixture` 启动时，App 按脚本自己导航、打开面板和小窗、拖动小窗，并通过 `DemoStage.signals` 设置悬停状态（卡片浮起、控件出现、进度条预览）。**不发送合成的鼠标或键盘事件，不移动真实指针**；录制期间 App 的窗口忽略真实指针。
   - **指针目标**：场景要指向的每个控件都标了 `.demoAnchor("<id>")`（Release 构建里什么也不做）。导演在指向的那一刻读取这个控件背后 NSView 在屏幕上的实际位置，所以画出来的指针正好落在控件上，弹出窗口和设置窗口里的控件也一样。找不到锚点时场景直接失败，录制脚本不会生成这张动图，不会再有「虚空点击」。
   - 每一步写进 `events.json`：时间、指针要去的屏幕坐标、点击、推近框、按键、字幕。
   - `MANPING_DEMO_ASSETS` 指向 `.assets/`：样本的封面和头像显示其中的照片；`MANPING_DEMO_MEDIA` 是这个场景的视频，在真实播放器里循环播放；弹幕来自样本接口返回的 XML。
2. **录制**（`record.swift`，ScreenCaptureKit）：启动调试版，为这个进程的每个窗口（主窗口、小窗、设置窗口、弹出窗口）各开一路 desktop-independent window 采集，保留窗口自己的透明圆角；窗口不必在最前，屏幕上其他内容不会被录进去。导演发出 `done` 后，每路录像转成 25 fps 的 PNG 序列（`.out/<场景>/w<窗口号>-<段>/`），再和窗口位置、层级、导演的事件合成时间线 `.out/<场景>.json`。
3. **合成**（`remotion/`，[Remotion](https://www.remotion.dev)）：每个场景一个 composition，把各窗口的帧按录到的位置放在柔和的渐变桌面上（阴影跟随窗口圆角），叠加 macOS 箭头指针、点击波纹、推近、按键胶囊和底部玻璃胶囊里的一行字幕，最后淡回第一帧以便循环。
4. **编码**（`remotion/render.mjs`）：渲染成 PNG 序列，ffmpeg 用单一调色板和有序抖动（bayer）编码成 `docs/images/<场景>.gif`（1280×800）。有序抖动让照片没有色带，又不像误差扩散那样让每一帧的每个像素都变化。静止段合并成长帧。单张超过 5 MB 时依次降到 20 / 15 / 12.5 / 10 fps，再缩小宽度重编；仍超出会打印提示（那时缩短静止段或场景）。

## 重新生成

```bash
scripts/readme_media.sh                   # 全部场景
scripts/readme_media.sh hero mini         # 只做这几个
scripts/readme_media.sh --no-build hero   # 复用已构建的 .build/ui/满屏 Debug.app
scripts/readme_media.sh --render-only     # 只用已有录像重新合成、编码
```

依次执行：`scripts/build_debug_app.py` 构建调试版 → `docs/media/fetch_assets.py` 下载素材（已有的跳过）→ 编译 `record.swift` 并逐场景录制 → `pnpm install` 后渲染。每个场景录制约 20 秒，期间调试版的窗口会出现在这台 Mac 的屏幕上。

需要：
- Xcode（`swift`、`swiftc`），以及 `build_debug_app.py` 要求的 Release 模板 `dist/release/满屏.app`（`python3 scripts/bundle.py --output "dist/release/满屏.app"`）；
- `ffmpeg`、`node`、`pnpm`；
- 运行脚本的终端要有「屏幕录制」权限（系统设置 › 隐私与安全性 › 屏幕与系统录音）。

单独调整一张动图时：在 Remotion Studio 里预览，只渲染那一个场景：

```bash
pnpm --dir docs/media/remotion studio
pnpm --dir docs/media/remotion render danmaku
```

### 不录屏的离线检查

`test-timeline.mjs` 用已有截图（主窗口的首页与视频页、小窗、设置窗口）手工组一条时间线，检查合成与编码：

```bash
node docs/media/test-timeline.mjs <截图目录>
pnpm --dir docs/media/remotion render test    # → docs/media/.out/test.gif
```

## 调整场景

- 场景脚本在 `DemoDirector.swift`（`hero()`、`danmaku()`…）：字幕、停顿、指针目标都在那里；启动参数（起始页面、窗口大小、用哪段视频）在 `scenes.json`。
- 指向新的控件时，先在它的视图上加 `.demoAnchor("<id>")`，再在场景里 `try await target("<id>")`。已有的锚点：卡片 `card.<标题>`、直播间 `live.<房间号>`、侧栏 `sidebar.<页面名>`、控制条 `bar.<项目>` 与 `bar.danmaku`、进度条 `seek`、章节 `chapters`、分段选项 `tab.<文字>`、滑块 `slider.<名称>`、设置分类 `settings.<分类名>`、直播输入 `live.composer` / `live.send` / `live.like` / `live.gifts` / `live.newLines`、AI 预设 `ai.<预设名>` 与时间点 `ai.time.<时间>`。
- 新增场景：`scenes.json`、`DemoDirector.perform()`、`remotion/src/Root.tsx` 的 `SCENES` 和 `render.mjs` 的 `SCENES` 各加一项。

Remotion 只用来生成这些文件，不属于 App。它有自己的许可：个人和小公司免费，见 [remotion.dev/license](https://www.remotion.dev/license)。
