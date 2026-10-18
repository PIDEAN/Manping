# 第一阶段关键链路证据

环境：2026-10-13，macOS 27.0.1、M1 Max 64GB、内置 XDR、Xcode 27、Swift 6.4。仓库最初为空 main；当前实现阶段为关键链路 baseline；用户完整交付条件不变，完整原生移植未完成。

## 重现与构建

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
python3 scripts/build_mpv.py
python3 scripts/generate_artcnn.py
python3 scripts/bundle.py --debug --mpv "$PWD/.build/mpv-build/libmpv.2.dylib" --output dist/patched/Manping.app
codesign --verify --deep --strict dist/patched/Manping.app
MANPING_MPV_LIBRARY="$PWD/.build/mpv-build/libmpv.2.dylib" python3 scripts/verify_shader_runtime.py
```

矩阵固定素材可重建（前8帧H264编码重建稍有变化，精确截图从1秒或render第30帧开始）：

```sh
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=30 -vf 'loop=loop=-1:size=1:start=0,setpts=N/30/TB' -t 18 -c:v libx264 -pix_fmt yuv420p -y /tmp/manping-static.mp4
# Golden 脚本需要 numpy，使用系统已有科学Python环境。
python3 scripts/verify_artcnn_golden.py
# 任一现有固定本地素材的实际候选probe：
env PATH=/usr/bin:/bin:/usr/sbin:/sbin dist/patched/Manping.app/Contents/MacOS/Manping --diagnose /tmp/manping-static.mp4 --sdr --preset ArtCNN/C4F32 --seconds 8 --report /tmp/manping-check.json
```

自建 mpv 为 release 库，App 为 Swift debug 候选；不覆盖 Homebrew。固定 v0.41.0 源码哈希、补丁和构建配置见 `scripts/build_mpv.py`、`patches/`、`Dependencies.lock.json`。77MB App 递归闭包 arm64/ad-hoc 验签通过；PATH 只有系统目录运行以下五组实际 bundle probe，dyld 日志无 `/opt/homebrew` 加载。未验证 Developer ID、公证或跨机分发。

Swift 6 严格并发 build、swift-format lint 和自写文件 diff whitespace 检查通过。10个测试：9通过，live API默认跳过1，无failure；其中真实 bundled FFmpeg合并独立H264/AAC并解码两轨，真实URLSession download delegate拒绝HTTP501。原样导入shader的既有whitespace未改。

## 渲染、HDR 与生命周期

`CAOpenGLLayer` 使用 ColorFloat/64-bit CGL pixel format，实测附件 `GL_FLOAT`、redBits16，当前 FBO/viewport由GL查询。VideoToolbox H264/NV12、HEVC Main10/P010均实际解码；mpv `vt_mac_gl` 通过 `CGLTexImageIOSurface2D` 映射解码IOSurface，未使用videotoolbox-copy。后续shader仍有正常GPU render pass，不将整个管线描述成完全无复制。

视频独立serial render queue；mpv update callback仅atomic dirty，播放可见8ms检查，暂停/隐藏/无媒体250ms检查，没有dirty不render。取消timer/callback、gate等待绘制完成、当前CGL中free render，再control queue terminate/free。Swift6 callback显式Sendable；CA display/flush不能持有gate，避免锁顺序反转。`@unchecked Sendable`不是运行时隔离保证，仍需要独立并发复核。

EDR空间为extendedLinearITUR_2020，与mpv bt.2020/linear一致。203nits reference white=1；每秒和屏幕变化更新当前headroom（向下取0.1），target-peak=203×当前headroom，potential只判支持。SDR使用bt.709/sRGB/203nits。`--headroom-cap 2`模拟受限当前headroom，实际峰值2.00195、target406；SDR同HDR素材峰值0.999512、target203，均0drop。见 [HDR限幅](evidence/cgl-hdr-headroom2.json)、[SDR回退](evidence/cgl-hdr-sdr.json)。[灰阶白点](evidence/hdr-white-levels.json)中50/203/1000nits输入约输出0.246/1/4.93。这里是数字信号机制证据，未用仪器验证物理亮度/色准，未实际调节系统亮度或测试外屏切换。

[4K60](evidence/cgl-4k60.json)：14秒HEVC/P010素材，约12秒观测。启动总drop14，媒体第1–11秒固定14；第3秒预热后drop增量0，decoder drop0。MainActor阻塞2秒期间后台增加121帧。cache约1–1.017秒，RSS第3–11秒约298–300MB；短时无持续增长，不代表长期稳定/功耗结论。测试顺序执行，没有另一个shader/编码测试并行，用户gate窗口仍开启，因此不是全系统GPU独占基准。

[暂停](evidence/cgl-pause.json)：3秒snapshot与7秒结束GPU帧数相同，poll250ms。[未知时长raw H264 FIFO](evidence/cgl-unknown-duration.json)：duration0仍poll8ms、59帧实际绘制；active依据pause/idle-active，不依赖duration。raw流探测耗时使该8秒probe不能当30fps性能结论。

[分离音频stress](evidence/cgl-split-stress.json)：2秒seek/pause，4秒reload，6秒销毁并重建PlayerModel/render/engine且重新应用F32，8秒seek，12秒记录后退出。error空、AAC已解码、F32 linkFailures0。诊断默认mute；CoreAudio有channel-layout warning，人工听感未验。loadfile用node map；`audio-files-append`使整个URL成为一项，不能用audio-files的冒号path-list或错误的%length%语法。`scripts/fixtures/audio_option.c`使用同样file-local node map，加载含逗号/冒号路径后查询实际external-filename逐字节相同，见 [fixture](evidence/audio-option-fixture.json)。

## Shader gate

原8个ArtCNN资源保留，派生8个在ArtCNNCompat。原六compute不支持macOS GL4.1，且最后LUMA COMPONENTS4与CHROMA组合导致copy_image断言；历史失败见 [原始abort](evidence/artcnn-original-abort.txt)。派生只改最后LUMA为1，中间RGBA特征保持4。

六compute用固定官方notebook cell7 generator和thin get_weights shim导出fragment；不训练、不改变权重文字。F16为26pass/12340参数，F32为50pass/47716参数；逐位置literal完全相同，源/输出/tensor hash见 [导出manifest](evidence/artcnn-export.json)。两Ani本身fragment，仅改最后COMPONENTS。完整原MIT头和官方generator许可保留。

F32原需17个vertex attributes（16纹理坐标+position），超过Apple GL16上限。最小mpv补丁只在render_pass_quad对实际四角UV（含变换/翻转/裁切/归一化）逐字节相同的坐标共享attribute/varying；texture/sampler仍独立。没有改公共API或用户shader算术。受控同renderer、稳定第30帧比较stock/patch C4F16，所有float像素相同，见 [补丁不变性](evidence/mpv-patch-invariance.json)。未patch库中F32五档仍可见禁用。

[最终矩阵](evidence/shader-runtime-matrix.json)：None+30档全部exit0，error空、linkFailures0；小源320×180→实际2314×1207保证WHEN触发，每档sampleHash不同None且有实际shader link。F32 activeAttributes2。Anime4K12、ArtCNN8、RAVU6、NNEDI3四档均执行；重档有启动/编译及运行drop，尤其NNEDI3 ProMax，不能声称全部实时或所有组合通过。

[同gpu-next黄金](evidence/artcnn-golden-gpu-next.json)：独立未patch mpv gpu-next/macvk，原compute与派生fragment，320×180→640×360，bt.709/sRGB/203nits/no dither，16bit PNG。两Ani逐像素相同；六compute PSNR61.23–63.72dB，max0.00636–0.00934。原compute FP16和fragment FP32舍入不同，非bit-exact。compute OOB texelFetch未定义；本机reference呈zero边界，派生显式zero，clamp→zero令F16边缘max约0.125→0.00514，见 [边界实验](evidence/artcnn-border-experiment.json)。不声称跨驱动未定义行为等价。

[完整管线抽样](evidence/artcnn-golden-full-pipeline.json)单独比较生产CGL派生F16 float PFM与原gpu-next原compute16bit输出。macvk将窗口高1207取整为1208，报告显式对reference双线性归一高度；MAE0.00524、PSNR32.23dB、max1。该结果包含几何/缩放/渲染路径差异，**完整管线黄金仍未达到等价验收，且未覆盖全部8项**，不可拿同gpu-next转换黄金替代此项。

## 网络与剩余项

早期live test：nav/popular/QR成功，匿名detail HTTP412、未请求playurl。用户之后WK扫码成功，root在旧App确认账号/热门、真实视频detail/playurl画质列表成功；旧版loadfile曾返回-4。候选已修typed map及音频path-list，但用户当前dist/gate等待SecurityAgent钥匙串授权；新版本Keychain恢复、真实BiliCDN分离音视频及HTTPS播放尚未验证。没有读取/记录Cookie值或绕过系统授权。日志redactor不保留signed URL、Cookie或QR密钥。

外屏、物理HDR、AV1/其它机型、长期热功耗、所有shader组合、真实下载/merge取消、全部页面/交互对齐、完整三方源码分发归档均未验收。当前media gate等待独立review及主agent对剩余黄金差异的判断，不代表首版全功能完成。

## 认证链路 fixture（2026-10-13）

认证协议及 exact commit 来源见 [Auth.md](Auth.md)。`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`：31 项 AuthTests 全通过；完整 41 tests、2 个 opt-in live/FFmpeg test skipped、0 failures。相关六个 Swift 文件经 `xcrun swift-format lint --strict` 通过，认证范围 `git diff --check` 通过。全仓 diffcheck 仍报告原 shader/vendor/patch whitespace，未修改这些范围。已有 Application/Player 并发/弃用 warnings 和 AppModel 下载 closure warning 保留，未据此宣称无 warning。没有运行真实账号认证或 Keychain 读写。旧 dist/gate 的用户手动 Keychain 授权及重启 Cookie 恢复由主 agent 实机观察；新 Token 持久化仍待验。

认证独立 review 的两项身份混合风险和一项 waiter race 已修复并新增 8 个受控 fixture；本轮最终 31 AuthTests / 41 总 tests（2 skipped）通过。修复前 33 tests 的通过不代表这些新增失败路径已经验证。实际命令日志 `/tmp/bili-auth-review-fixes-test.log`、`/tmp/bili-auth-review-fixes-build.log`；真实 OS prompt 取消仍未验证。


## Release integration 媒体 review 修复（2026-10-13）

本轮候选 `dist/integration/Manping.app` 为 Swift **Release**（历史 `dist/gate`/`dist/patched` 未覆盖）。命令：`python3 scripts/bundle.py --output dist/integration/Manping.app`；默认 `.build/mpv-build/libmpv.2.dylib`，缺失提示 recipe。输入锁仅由显式 `--update-lock` 更新；实际当前 closure 为44 dylib和独立FFmpeg executable input SHA。`python3 scripts/bundle.py --verify-inputs` 强制核对 closure/hash/MpvBuild/两patch；[负例fixture](evidence/bundle-input-lock-fixture.json)证实 missing/extra/hash/FFmpeg hash/metadata不匹配均拒绝。

[Bundle verification](evidence/bundle-integration-release.json)：`python3 scripts/verify_bundle.py` 重算外置 manifest 全46 final signedSHA256、全arm64、relative runtime dependencies、无Homebrew RPATH及strict codesign；system-only PATH启动 App 和 bundled FFmpeg exit0，dyld实际libmpv来自bundle且无Homebrew加载。内置manifest主exe明确为before-app-resource-seal；whole-app signing之后的主exe final SHA只能存app外，以避免resource-seal循环。参见 ThirdPartyNotices/README.md。

`build_mpv.py` 用verified archive全新提取、两patch固定hash、全新Meson build。受控[clean-source fixture](evidence/mpv-clean-recipe-fixture.json)实际应用两patch，注入无关dirty文件及修改已patch文件后再次提取，dirty文件消失、patched file hash恢复一致；本轮未重新运行整个Meson编译，bundle使用已锁定的existing release patched libmpv。

`GlyphCachePolicy` 保留最多8历史页，active pages独立；稀疏页超过`ceil(unique/256)+8`时，将已缓存bitmap复制到新immutable generation，避免重复CoreText栅格化。每frame先固定全部glyph→generation/slot，再生成vertices；每command强保留纹理直到completion，不改写in-flight texture，也不因cache满静默丢字。每页1024² BGRA8 =4MiB。XML每条≤160字符、draw≤100条，资源上界随单帧有效unique而有限，历史不随整段视频增长；最多3个in-flight command，共享同页不复制纹理。没有每弹幕SwiftUI view。

[实际Metal字形probe](evidence/danmaku-glyph-probe.json)：Release/system PATH，2048不同CJK字符后重复出现旧/新字形，rasterized仍2048；当前frameGlyphs=vertexGlyphs=1024，active4/history4，peak resident8页=32MiB、in-flight3，command保留的页峰4（跨command共享）。[drawable PNG](evidence/danmaku-metal-glyphs.png)为实际Metal render后blit到shared buffer、完成fence后导出的原尺寸2314×1207图，包含旧/新字形；仅`--glyph-probe`开放readback。正常生产无drawable readback。纯fixture覆盖累计>1024、单帧3072 unique重复prepare无新页、历史淘汰/旧frame generation不变、稀疏active compaction无需重新栅格化已有glyph。

[关闭提交probe](evidence/danmaku-submit-probe.json)：关闭后清一次屏幕并暂停MTKView，3s和5s submits均78；6s重启后7.5s增加至153。resize/启用通过main callback唤醒，stop取消observer并阻止排队callback复活。暂停/resize清屏路径由代码和fixture范围审查，尚未做单独真实交互采样。

[固定full-pipeline golden](evidence/artcnn-golden-full-pipeline-fixed.json)：`python3 scripts/verify_full_pipeline.py --build-mode release`（需numpy）。生产VideoSurface/VideoLayer只创建一次；同一lossless static H264帧，双端software decoder，actual FBO/reference均1280×720。actual osd margins全0，未经事后resize或ROI crop；记录实际public properties、FBO及input/output SHA。None和八ArtCNN共9项native exit0、error空、linkFailures0。None PSNR41.30946/max0.11061；八档PSNR41.92325–42.12836/max0.04813–0.05353。八档完成取样**不等于等价验收**；公开target-trc=srgb等property相同也不证明内部transfer映射完全相同。历史2314×1207 vs1208双线性结果保留为无效等价对照，不能用于真正功能缺陷判定。

[两个None color controls](evidence/artcnn-none-color-controls.json)：`python3 scripts/verify_color_controls.py`，生产和权重未改。reference `treat-srgb-as-power22=no`与default PNG/hash/numeric完全相同；再`target-contrast=inf`改善PSNR到45.39514，max反而增为0.13309。实际getter记录false和auto/inf，完整矩形及color/range/ICC不变。verified v0.41.0 archive的`vo_gpu_next.c`可核对内部SRGB→GAMMA22分支和contrast分支；本机libplacebo `colorspace.h`定义unknown SDR contrast1000，legacy `video_shaders.c` BT1886使用pow2.4。这些受控结果只能解释部分差异，剩余renderer/precision/scaling机制尚未隔离；不扩大参数sweep、不修改shader权重，最终gate交由主agent判断。

最终`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --arch arm64`：47 tests、2 skipped、0 failures（新增6 MediaPolicyTests全过）。Swift Release build、相关7个Swift文件`xcrun swift-format lint --strict`、Python py_compile、限定修改文件diffcheck通过。全仓diffcheck仍包含原样shader/vendor/patch既有whitespace，未清理它们。Application诊断参数测试覆盖签名audio URL完整保留、file本地路径、缺参数/空值/不合法scheme/seconds/hwdec/bvid以及固定pixel geometry。下载picker只改为非阻塞completion后enqueue；真实UI、Keychain、publicBV稳定CDN/音轨、本机听感、外屏物理HDR、长期功耗和全功能/视觉移植未验收。未运行真实账号认证或发布互动，未commit/push/merge。


None残差[空间定位](evidence/artcnn-none-difference-locations.json)：max在(x62,y14)的Blue通道，素材自身烧入timestamp的字缘；高误差还沿斜线、色度边界和格纹分布。reference/static source/difference图只读检查未见player OSC/cursor；左上00:00:00.000本来存在于testsrc2 PNG中。>0.02差值覆盖8.9%pixels，whole MSE7.397e-5；中心范围MSE8.690e-5（仅分布统计，不用于主golden裁切），不是只发生在外围控制条。lossless视频实际720帧framemd5仅一个值，排除了native第30帧与reference首帧的内容时间差。尚未把这些边缘残差归因于某个scaler或shader kernel，也未发现足以触发OSD污染重测的证据。

## None sigmoid 控制与 RPC review 修复（2026-10-13）

[单个 sigmoid 实验](evidence/artcnn-none-sigmoid-controls.json)：`scripts/verify_sigmoid_controls.py` 使用 `dist/diagnostics/Manping.app`（Swift Release、默认 patched mpv closed inputs），不覆盖 integration。继续使用原 `.build/full-pipeline/static.mp4`，SHA256 `5ea74daf49e1de18c2a77af8b42330654aed77cb3eadce4f8b293ea1e86b22b1`；实际 framemd5 720 帧仅一个值。四个有效 captures 为新 CGL None baseline/control 和 stock mpv gpu-next/macvk baseline/control；唯一控制参数为两端 `sigmoid-upscaling=no`。先确认双方实际 `linear-upscaling=no`，baseline sigmoid=yes、control=no；software、709/limited/bt1886 源、709/sRGB/203 目标、bt2390、三 bilinear、no dither 均固定。实际两端 chroma-location 均为 `mpeg2/4/h264`，未改变或试验 chroma。

所有图像完整 1280×720、osd margins 全零；CGL FBO 为 GL_FLOAT/redBits16，PFM 保存原 float 值，reference PNG 为16bit。未 clamp native、未 ROI crop、未事后 resample。新 CGL baseline PFM hash 与既有 None.pfm 相同（`c35ad022…`）。control PFM hash `c5fa95b1…`；reference 两张 PNG hash 均 `8466bbc7…`，逐像素差值为0。CGL selfdiff：921214 个像素改变、MAE0.000742257、max0.127868652、PSNR47.17846。跨端 baseline→control：PSNR41.30946→41.62573、max0.110610861→0.099605255，MAE反增0.002532301→0.002582563。该结果支持本素材的缩放路径假说，改善有限，不能称为 pixel-equivalent 或 full gate 通过；未扩展八档、未修改 production Player/bridge/options/shader/weights。

verified mpv0.41 [legacy video.c](https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/gpu/video.c#L2582) 在放大时使用 linear/sigmoid；libplacebo7.360.1 [renderer.c](https://github.com/haasn/libplacebo/blob/v7.360.1/src/renderer.c#L2021) 的 direct sampling/!need_fbo 提前分支先于 linearize/sigmoidize，[sampling.c](https://github.com/haasn/libplacebo/blob/v7.360.1/src/shaders/sampling.c#L131)允许 direct shader 可变输出尺寸。源码和输出完整 SHA 在 JSON 中。reference vo-passes 只见 color decoding 和 frame mixing/color encoding；CGL public vo-passes getter 返回 unavailable(-1)、已有 passes 为空，无法把静态源码分支判断当成实测 CGL hook trace。首轮 profile checker 将 IPC Bool false 与 string no 区分而中止，尚未 reference 截图/control；修正 Bool 规范化后重做四个有效 captures，保留中止 log，没有新增参数变体。

命令：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/bundle.py --output dist/diagnostics/Manping.app`；使用带 numpy 的 bundled Python 运行 `scripts/verify_sigmoid_controls.py`。`scripts/verify_bundle.py` 的现有 main 在 `.build/sigmoid-controls/bundle-verifier` 输出根目录运行，app 指向 diagnostics；保留原 integration evidence。[诊断 bundle evidence](evidence/bundle-diagnostics-release.json)：46 Mach-O／44 dylib 的 final SHA、全arm64、relative闭包、strict codesign、system-only PATH／dyld无Homebrew加载均通过。integration executable SHA仍为 `a204485a…`。诊断包／四 captures 先封存，再修纯 RPC；最新源后续 Release build 单独验证，不覆盖两包或重复 golden。

RPC 四项修复及新增5个 fixture见 [RPC.md](RPC.md)。最终全量70 tests、2 skipped、0 failures；相关6个Swift文件 strict lint、Python py_compile、限定 diffcheck 通过。log 在 `.build/sigmoid-controls/{final-swift-test.log,final-release-build.log,experiment.log,bundle-verification.log}`。真实账号／Keychain、线上RPC／视频、人工听感、物理HDR、UI接线及完整移植仍未验收，未commit/push/merge。


## 受限 renderer compatibility（2026-10-13）

[实现范围与公式](RendererCompatibility.md)：第三份独立 mpv patch 修复严格条件下的 direct bilinear plane sampling，以及 metadata-aware SDR BT.1886 到受支持 sRGB/LINEAR 的黑位语义。LINEAR/SIGMOID hook、常见 resize 和字幕混合使用同帧 policy；动态系数为 uniform，actual current-frame metadata 更新及暂停重绘均有实测。Swift production、CMpv 和 shader 权重未改。新候选只写 `dist/renderer/Manping.app`。

[最终固定 sRGB golden](evidence/renderer-golden-final.json)：生产 VideoSurface 的原始 full1280×720 PFM vs stock gpu-next 原 shader，None+8档全取样，reference SHA 与既有 fixed baseline 相同。None PSNR68.7939/max.002058；两 Ani 66.6956/max.002455、67.3573/max.002562；六 derived 59.3902–63.6825/max.007308–.010542。没有 ROI、resize、capture 后校正或放宽指标，`pixelEquivalent=false`。这些是诊断 sRGB 的同条件指标，不能当作正常窗口 LINEAR 的黄金比较。

[LINEAR transfer oracle](evidence/renderer-linear-final.json)：精确码值 FFV1 neutral bars 对照 linked-libplacebo CPU inference/EOTF，auto peak203/406/3248、inf、contrast2000、source min=.1 最大误差约.0004884。[28项CGL回归](evidence/renderer-regressions.json) 记录真实 pass 与逐项 SHA：非整数/up/downscale、crop/rotation/odd、alpha、LINEAR/SIGMOID hook、有效字幕、实际metadata变化、暂停20次peak更新。active和paused的20次更新均没有比各自baseline更多的shader links；paused所用shader source hashes相同。PQ/P010 linear406/3248、sRGB203及HLG10bit完整 raw captures 与封存旧libmpv逐像素相同。

[正常production窗口](evidence/renderer-production.json)：None/两Ani实际target=LINEAR BT2020、peak203/406；默认lanczos/sigmoid非整数viewport的原始neutral RGB另行记录。None neutral white原始RGB为[.996094,.998047,.995117]（bounded sampledPeak=.998535），未把固定bilinear oracle阈值挪用于此。首次harness要求全部draw均background的断言被CA首次同步draw触发；依据既有CA设计改为实际main-stall进展，保留失败log且未改变renderer。最终pause frame56在3s→6s稳定，main-stall2s frame86→146；split AAC/seek/reload/destroy exit0、time11.9s、AAC存在。HDR50/203/1000 bars的headroom2/16及SDR回落均VT执行，正常窗口也保留大于1的float值。物理亮度、跨外屏与全部metadata组合未验证。

[真实中间格式](evidence/renderer-internal-formats.json)：C4F32原compute实际rgba16f，legacy派生fragment也使用rgba16f，不因模型名字强改rgba32f；六derived残差未被错误归因于FP32存储丢失。[干净源码/资源](evidence/renderer-source-recipe.json) 验证三patch和dirty-source重建保护，79份原始/派生shader hashes完全不变。[闭包输入](evidence/renderer-closure-inputs.json) 仍44库，只有libmpv输入SHA变更。

最终clean source C/Meson build、Swift70tests（2skipped/0fail）、release build、两个C fixtures的-Wall/-Wextra/-Werror、Python py_compile和限定diffcheck通过。release首次XCBuildData I/O/incomplete-target错误在隔离生成缓存后串行构建恢复；磁盘空间充足且SQLite完整性检查正常，保留失败log，不断言磁盘损坏。未改动Auth/RPC，未使用真实账号或联网视频，未commit/push/merge；真实账号联调由主agent另行记录。
# 暂停时状态补记（2026-10-13）

用户要求在安全节点停止以审查方向，开发／测试队列已经结束。完整恢复记忆与待审方向见根目录 [Ledger.md](../Ledger.md)。本文较早段落保留当时事实，不能作为最新全量状态。

最新封存 `dist/renderer/Manping.app` 的 signed executable SHA256 为 `1b15972c510761a69d21cbc20a0d5effe2ad325dbe71abd6753204d15dc25865`；[bundle](evidence/bundle-renderer-release.json) 确认44 dylib、46 Mach-O全部arm64／最终hash、strict signature、system PATH运行无Homebrew加载。Swift70tests／2skips／0fail；新renderer独立review尚未开始。

[runtime](evidence/renderer-shader-runtime.json) 的31项exit0/linkFailures0不能等同31项有效播放通过：NNEDI3 ProMax首次初始化20.24s，只有3frames、time0、无sample，标记**未验证**；NNEDI3 Pro记录118drops。用户暂停后未进行延长采样。固定[sRGB全图](evidence/renderer-golden-final.json)保留`pixelEquivalent=false`，六derived数值残差已披露；[production LINEAR](evidence/renderer-production.json)单独记录，物理HDR／跨外屏／完整性能未验证。

integration封存包已由用户完成真实TV App Token登录和同包重启恢复；[public VT样本](evidence/live-bv-vt.md)仅验证特定qn80素材。最新renderer包未进行真实账号／线上RPC联调；现有Web WBI播放请求与原版App签名REST的差异尚未移植。下一模块未启动，完整移植未完成。

