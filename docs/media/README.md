# README 动图

`docs/images/*.gif` 全部来自调试版在**离线样本**（`--ui-fixture`）上的真实运行画面：首页、视频、直播间、设置里的内容都是本地合成数据，视频是 ffmpeg 画出来的风景，弹幕和直播聊天是写死的虚构句子，没有任何真实账号、用户名或 B 站内容，也不发网络请求。

| 动图 | 场景 | 内容 |
|---|---|---|
| `hero.gif` | `hero` | 首页网格 → 悬停卡片浮起 → 打开视频，弹幕滚动、玻璃控制面板 → 悬停进度条（预览与「时间 · 章节名」）→ 停下 2.5 秒后控件淡出 |
| `danmaku.gif` | `danmaku` | 弹幕特写（推近）→ 弹幕面板：显示区域半屏 → 全屏、字号调大 → 关闭再打开弹幕 |
| `mini.gif` | `mini` | ⇧⌘P 打开小窗（右下角）→ 主窗口切到首页、专栏，播放不中断 → 悬停小窗出现玻璃控件 → 拖到左上角吸附 |
| `live.gif` | `live` | 直播网格 → 进入直播间 → 聊天滚动、醒目留言 → 往上翻看时出现「N 条新弹幕」 |
| `settings.gif` | `settings` | ⌘, 打开设置窗口 → 网络（节点与代理）→ 致谢 |

## 怎么做出来的

1. **演示导演**（`Sources/ManpingApp/DemoDirector.swift`，只在 Debug 构建里存在）：`MANPING_DEMO_SCENE=<场景>` 加 `--ui-fixture` 启动时，App 按脚本自己导航、打开面板和小窗、拖动小窗，并通过 `DemoStage.signals` 设置悬停状态（卡片浮起、控件出现、进度条预览）。**不发送合成的鼠标或键盘事件，不移动真实指针**；录制期间 App 的窗口忽略真实指针，桌面上的鼠标不会影响画面。
   - 每一步写进 `events.json`：时间、指针要去的屏幕坐标（无障碍树里找到的控件中心，找不到时用窗口内的比例位置并在 `notes` 里说明）、点击、推近框、按键、字幕。
   - `MANPING_DEMO_MEDIA` 指向的本地视频（`demo-media.sh` 生成，带四个章节）代替样本的静态封面在真实播放器里播放；弹幕来自样本接口返回的合成 XML。
2. **录制**（`record.swift`，ScreenCaptureKit）：启动调试版，为这个进程的每个窗口（主窗口、小窗、设置窗口、弹幕面板这类弹出窗口）各开一路 desktop-independent window 采集，保留窗口自己的透明圆角；窗口不必在最前，屏幕上其他内容不会被录进去。导演发出 `done` 后，每路录像转成 25 fps 的 PNG 序列（`.out/<场景>/w<窗口号>-<段>/`），再和窗口位置、层级、导演的事件合成时间线 `.out/<场景>.json`。
3. **合成**（`remotion/`，[Remotion](https://www.remotion.dev)）：每个场景一个 composition，把各窗口的帧按录到的位置放在柔和的渐变桌面上（阴影跟随窗口圆角），叠加 macOS 箭头指针、点击波纹、推近、按键胶囊和底部玻璃胶囊里的一行字幕，最后淡回第一帧以便循环。
4. **编码**（`remotion/render.mjs`）：渲染成 PNG 序列，ffmpeg 用单一调色板编码成 `docs/images/<场景>.gif`（1280×800）。静止段合并成长帧；镜头运动每 80 ms 一步、淡入淡出分档，因为 GIF 会重绘每个变化的像素。单张超过 2.5 MB 时自动降到 20 / 15 / 12.5 fps 重编，仍超出会打印提示（那时缩短静止段或场景）。

## 重新生成

```bash
scripts/readme_media.sh                   # 全部场景
scripts/readme_media.sh hero mini         # 只做这几个
scripts/readme_media.sh --no-build hero   # 复用已构建的 .build/ui/满屏 Debug.app
scripts/readme_media.sh --render-only     # 只用已有录像重新合成、编码
```

依次执行：`scripts/build_debug_app.py` 构建调试版 → `docs/media/demo-media.sh` 生成演示视频（只在缺失时）→ 编译 `record.swift` 并逐场景录制 → `pnpm install` 后渲染。每个场景录制约 15 秒，期间调试版的窗口会出现在这台 Mac 的屏幕上。

需要：
- Xcode（`swift`、`swiftc`），以及 `build_debug_app.py` 要求的 Release 模板 `dist/release/满屏.app`；
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

- 场景脚本在 `DemoDirector.swift`（`hero()`、`danmaku()`…）：字幕、停顿、指针目标都在那里；启动参数（起始页面、窗口大小、是否播放演示视频）在 `scenes.json`。
- 一次录制后先看录制输出里的 `director:` 行：列出没在无障碍树里找到、改用比例位置的目标，按需调整比例。
- 新增场景：`scenes.json`、`DemoDirector.perform()`、`remotion/src/Root.tsx` 的 `SCENES` 和 `render.mjs` 的 `SCENES` 各加一项。

Remotion 只用来生成这些文件，不属于 App。它有自己的许可：个人和小公司免费，见 [remotion.dev/license](https://www.remotion.dev/license)。
