# CGL renderer 受限兼容策略

本轮只修改 vendored mpv v0.41.0 的 `video/out/gpu/video.c`，作为第三份独立 patch 应用。Swift production、CMpv callback/线程 ownership、窗口嵌入、原始和派生 shader 权重均未修改。候选包为 `dist/renderer/Manping.app`；`dist/integration`、`dist/diagnostics` 保持封存。

## 语义与范围

原 legacy pipeline 将无 shader 的 YUV420p 先转为源尺寸 RGB，再把 RGB 放大；gpu-next 的 direct sampler 可直接在最终尺寸采样各 plane。新 direct 路径只允许实际解析后 scale/cscale/dscale 均为 bilinear，且无 user hook/texture、alpha、interpolation、字幕混合、HDR、crop、rotation、奇数源尺寸、不支持的 texture transform。subsampling 必须整除尺寸。任一条件不满足时继续原中间纹理路径。`inherit` 按其实际 scaler 解析；没有改变其它 scaler 的实现。

颜色策略只处理 display-referred SDR BT.1886 到同 primaries 的 sRGB，或 BT.709 到 BT.709/BT.2020 linear。排除 LUT、alpha、interpolation、显式 gamut/inverse tone 配置，以及需要 tone mapping、black-point adaptation 或 gamut compression 的 metadata 形状。策略按值读取当前实际显示 frame 的 `params.color.hdr`，其余格式使用 renderer 已配置参数；没有全局改写旧 HDR metadata 路径。无 current frame 时安全 fallback。

源/目标黑白点直接调用已链接的 libplacebo 7.360.1 `pl_color_space_infer_map` 和 `pl_color_space_nominal_luma_ex`。BT.1886 的有限对比度 EOTF 为 `a * pow(max(V, 0) + b, 2.4)`，其中 `a = (Lw^(1/2.4) - Lb^(1/2.4))^2.4`，`b = Lb^(1/2.4)/(Lw^(1/2.4) - Lb^(1/2.4))`，L 使用 libplacebo 的 nits/203 归一单位。

- sRGB：按目标黑白点归一，再应用 piecewise sRGB 编码，最后在 renderer shader 内限制到 `[0,1]`。原超白输入并未在 capture 后校正；初版未限制输出的实验也单独保留。
- production linear：输出相对于 203 nits SDR white 的 linear 值；不除以 target peak、不 clamp 到 1。BT.709→BT.2020 仅使用原色矩阵，不新增 gamut/tone 算法。
- 非整数 resize、ArtCNN LUMA2x 后 main downscale：缩放前与 final color mapping 使用同一帧 policy。LINEAR/SIGMOID hook 继续执行，字幕混合需要的 inverse EOTF 与后续 EOTF 成对对应，避免重复应用黑位。
- EOTF、inverse EOTF、目标归一系数均为 uniform；metadata 数值变化不写入 GLSL literal。policy 变化使缓存输出失效，暂停 peak 更新也会重绘。

## `target-contrast`

复用 mpv 已注册的 option，没有新增 public option。只在以上受支持形状执行：`auto` 保留真实目标 min metadata 并交给 libplacebo 推断；`inf` 使用 gpu-next 同一 `1e-7` nits 黑位约定；正数将目标黑位设为 nominal target max/contrast。未知源 min=0 与明确源 min（例如 .1 nits）通过实际 frame metadata 区分。

不支持的 source/target 形状沿用 legacy renderer。verbose log 给出 fallback reason；显式 `target-contrast` 未执行时给出 warning，getter 接受值不代表所有 TRC 都支持。例如已知 source min=.1、target peak406/contrast1000 需要 black-point adaptation，明确 fallback。PQ/HLG 不套用 SDR 黑位策略。

## 验证与证据

`renderer-golden-final.json` 是实际 production VideoSurface/CGL 的诊断 sRGB 固定 1280×720 输出，对比 stock gpu-next 原 shader；同一软件解码静态 input、完整原始像素，无 ROI、resample 或 capture 后修正。它不代表日常 production LINEAR 输出，`pixelEquivalent=false` 保留数值差异供验收。

`renderer-linear-final.json` 使用解码逐字节一致的 YUV neutral bars，对比独立 linked-libplacebo CPU inference/EOTF；覆盖 auto peak203/406/3248、inf、contrast2000、明确 source min=.1。最大误差约一个 RGBA16F 步长 .0004884；该项是 transfer/white-point 验证，不是全图 GPU 等价证明。

`renderer-regressions.json` 记录实际 pass、properties、library/input/capture/log SHA，覆盖非整数放大、下采样、crop、rotation、odd、alpha、LINEAR/SIGMOID hook、有效字幕、实际 frame metadata 更新、active/paused peak 序列。20 次 peak 更新与各自 active/paused baseline 的 shader links 相同；暂停缓存路径可多一次相同 shader source 的链接。PQ/P010 的 linear406/3248 与 sRGB203，以及 HLG10bit 的 raw captures 与封存 integration libmpv 逐像素相同。早期已通过的几何结果保留各自 library SHA，metadata 修复后只重测相关失效点。

`renderer-production.json` 单独记录正常窗口、真实 VideoSurface 的 LINEAR BT.2020 target、None/两 Ani 在 headroom1/2 的输出、HDR50/203/1000 bars、SDR fallback，以及 pause、main-thread stall、split AAC/seek/reload/destroy。`renderer-shader-runtime.json` 记录原有 30 个 presets 加 None 的 production LINEAR 路径运行情况。

[实际中间格式证据](evidence/renderer-internal-formats.json) 中，原 C4F32 的名称不是内部 FP32 格式声明：固定 libplacebo reference 的实际 compute output 为 `rgba16f`，其 `get_hook_tex` 通过默认 FBO format 选择；原 shader 没有 FORMAT override。legacy 实际 trace 同样使用 rgba16f。因此本轮没有无证据改为全局 rgba32f。六个派生网络仍有比两个 Ani 更大的数值残差，不能将这些差异归因于尚未证明的 FP32→FP16 存储变化，也不能据此宣称完整 pixel equivalence。

## 构建与边界

`renderer-source-recipe.json` 固定 archive/三份 patch SHA，验证污染源码重新 clean extraction，79 份原始/派生 shader SHA 未变。`RendererCompatibility.json` 保存参考 source SHA 与许可。`Dependencies.lock.json`、app 的 `MpvBuild.json` 和 app 外 `BundleManifest.json` 记录实际输入及最终 signed Mach-O；闭包保持 44 dylib + 2 executable。

本轮没有验证物理 HDR 屏幕亮度、跨外屏切换、所有 ICC/gamut/tone 配置、所有用户 shader 或全部视频 metadata 组合。上述 fallback 表示保留旧行为，不表示完整移植 gpu-next。没有使用真实凭据、账号或联网视频执行这些 renderer probes。

## 固定 sRGB 全图指标

| Pipeline | PSNR dB | 最大绝对误差 |
| --- | ---: | ---: |
| None | 68.7939 | .00205834 |
| Ani4Kv2 | 66.6956 | .00245534 |
| AniSD | 67.3573 | .00256195 |
| C4F16 | 61.6961 | .00730822 |
| C4F16_DN | 60.8968 | .00793399 |
| C4F16_DS | 60.1801 | .00753893 |
| C4F32 | 63.6825 | .01054176 |
| C4F32_DN | 59.3902 | .00859036 |
| C4F32_DS | 61.8533 | .00904641 |

九份 reference PNG SHA 均与原固定 baseline 相同。上述是测量值，没有新增或放宽数值验收阈值。None 从原 41.3095 dB 提升到 68.7939 dB；派生网络仍有已披露残差。

正常窗口默认 `scale=lanczos`、`dscale=hermite`、`sigmoid-upscaling=yes`，实际2314×1181且有aspect margins。它与固定bilinear oracle条件不同，neutral white原值仅记录，不使用后者阈值判等价；None neutral white原始RGB为 [.996094, .998047, .995117]（bounded sampledPeak为.998535）。首次production harness曾错误要求所有CA draws都发生于后台，实际首次同步draw使148frames中147background而中止；改为核验实际main-stall期间后台继续推进，保留首轮log。renderer实现未因此改变。release首次构建遇到XCBuildData/build.db I/O/incomplete-target错误，数据库完整性检查正常、磁盘空间充足；隔离该生成缓存后串行release成功。共享构建缓存是可能原因，未证明磁盘损坏。
