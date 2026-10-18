# 来源与许可

- 上游 BiliCopilot：`https://github.com/Richasy/BiliCopilot`，固定 commit `896a06290ba440cb17776d292dff119bbd3383d6`。仓库 LICENSE 为 GPL-3.0；本项目根 LICENSE 保留全文。
- mpv：项目自建 patched `mpv 0.41.0`（默认 bundle 输入）；`https://github.com/mpv-player/mpv/tree/v0.41.0`。C client/render headers 来自该安装版本，保留 ISC-style 许可头。实际 mpv binary 的 GPL/LGPL 选择以 `MpvBuild.json` 构建选项和上游默认 GPL 开关为准。
- FFmpeg：Homebrew 9.0.2（此环境通过 `brew install mpv` 连带更新 dependencies），实际 `-buildconf` 启用 GPL、version3、OpenSSL、VideoToolbox；`https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz`。不能把本构建笼统标为 LGPL。
- shader：由固定上游 `src/Desktop/BiliCopilot.UI/Assets/{Anime4K,ArtCNN,nnedi3,Ravu,igv}` 原样复制。Anime4K/ArtCNN保留 MIT头，RAVU/部分igv/nnedi3许可见各文件原始头；没有移除许可或权重署名。
- 系统 frameworks：AppKit、SwiftUI、OpenGL、MetalKit、Security、Foundation、SQLite3；随 macOS 提供。
- 原生 RPC：`grpc-swift-2 2.4.3`、`grpc-swift-nio-transport 2.10.0`、`grpc-swift-protobuf 2.4.1`（Apache-2.0）与 `swift-protobuf 1.39.0`；所有直接／传递 Swift packages 固定于 `Package.resolved`，上游 LICENSE／NOTICE 与逐文件 hash 存于 `SwiftPackages/manifest.json`。生产 target 选择 `GRPCNIOTransportHTTP2TransportServices`，使用 Network.framework 的 TLS 与 ALPN。
- BiliKernel 协议及 adapter 参考：`https://github.com/Richasy/bili-kernel`，固定 `22fdf8ca04bab384b46536b05f6524a41f83a2d4`；GPL-3.0 全文在 `BiliKernel-LICENSE`。22 个 `.proto` 保留原始反编译来源注释；协议与参考 C# 文件 hash 在 `Protocols/BiliKernel/manifest.json`。`google/protobuf/any.proto` 来源为 `libprotoc 36.2` 安装包，保留原头，许可在 `GoogleProtobuf-LICENSE`。
- CDN 优选策略：移植自 Bili CDN Switcher（`https://github.com/liiliiliil/bili-cdn-switcher`，MIT），包括候选节点、两阶段测速和卡顿判定规则，用 Swift 重写，未逐字复制代码；许可全文见 `BiliCdnSwitcher.md`。多节点中继、智能缓存和自动降画质为本项目自行实现。
- CA certificate bundle：来自 Homebrew `ca-certificates` 安装的可信根资源，完整 bundle 同时复制使用。

随附 dylib 和 FFmpeg 可执行文件的许可全文在 `Libraries/`，由 `scripts/collect_licenses.py` 从对应 Homebrew keg 原样复制，`Libraries/README.md` 列出每个库的来源版本与 SPDX 许可。

`Dependencies.lock.json` 记录当前 patched mpv + FFmpeg executable 的精确输入闭包：44 个 dylib，及独立 FFmpeg executable 的 input SHA-256。旧 Homebrew-only 48 库清单已替换；当前不包含 libarchive/libb2/liblz4/libzstd。`scripts/bundle.py` 在 copy/rewrite 前校验 closure 集合、所有 input SHA、MpvBuild 完整元数据和三份固定 patch SHA；缺项、多项和 hash 变化均失败，只有显式 `--update-lock` 更新输入锁。默认使用 `.build/mpv-build/libmpv.2.dylib`；缺失时提示 `python3 scripts/build_mpv.py`。

app 内 `Resources/BundleManifest.json` 记录每个 Mach-O 的 relative bundledPath、arm64、改写后的 dependencies、inputSHA256 和签名阶段。dylib/FFmpeg 的 signedSHA256 为最终值；主 executable 明确标为 `before-app-resource-seal`，因为 whole-app signing 会改变其 resource seal。app 外同级 `BundleManifest.json` 在 whole-app signing 后记录全部 46 个 Mach-O 的最终 signedSHA256，并执行 strict codesign verification；外置清单不受 app resource seal 保护，验真须自行重算 SHA。不能把改写后的 SHA 当成 source input SHA。

`build_mpv.py` 每次从已验证 archive 干净解压并应用三份 hash 固定的 patch，同时重新创建 build 目录；不再依赖 reverse-applicable patch 认定整个源码树干净。

对外分发构建产物（例如 GitHub Release）时，须保留本目录的全部许可，并提供对应源码与构建说明：本仓库源码、`patches/` 与 `scripts/build_mpv.py` 固定的 mpv 0.41.0 源码、以及 `Dependencies.lock.json` 列出的 FFmpeg 等依赖版本。动态链接或 ad-hoc 签名不能代替 GPL/LGPL 的分发义务。

## macOS shader gate 派生资源

- `ArtCNNCompat` 是独立兼容目录；上游 `ArtCNN` 八份原始资源不改。六份 compute 模型经 Artoriuz/ArtCNN `8789539dfae120f2877a89bb6218026d56809612` 的 `Notebooks/ArtCNN_C_Keras.ipynb` cell 7 官方 `generate_shader_code` 重新导出，函数原文位于 `scripts/vendor/artcnn_fragment_generator.py`，MIT 许可在同目录 `ArtCNN-LICENSE`；数值以原字符串逐位置验证，未训练模型。
- 六份派生 fragment 明确使用 zero padding，与本机 macvk 原 compute 的实测越界结果一致；这不是所有驱动上未定义 `texelFetch` 越界行为的保证。八份兼容文件的末尾 LUMA pass 声明修正为 `COMPONENTS 1`，中间四通道特征不变。原始许可头仍在每个派生资源中。
- 自建 libmpv 固定 v0.41.0 archive，SHA-256 `ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209`；`patches/mpv-0.41.0-deduplicate-quad-coordinates.patch` 只在 raster quad 构建中按四角实际 UV 的完全相同 float 字节复用 varying，texture/sampler 和 compute 路径不变。`mpv-coreaudio-device-change.patch` 是 Homebrew 已采用的上游 `c5d391adba7bd024954d0df1e0405f5749f4d4ca` 修复。
- `scripts/build_mpv.py` 保留独立源码和构建目录，不安装到 Homebrew。构建 GPL 默认开启；对应许可和 Copyright 一并保存在本目录，app 内附 `MpvBuild.json` 及 patch 哈希。完整第三方依赖的源码归档仍未完成。

## 受限 renderer compatibility patch

`mpv-0.41.0-renderer-compatibility.patch` 在原两份 patch 之后应用。它为符合严格条件的 bilinear plane sampling 省去 RGB 中间纹理，并为 display-referred SDR BT.1886 到受支持的 sRGB/linear 目标添加 metadata-aware 黑位策略。推断直接调用现有链接的 libplacebo 7.360.1 API；EOTF、inverse EOTF、sRGB 归一公式参考该版本 `src/shaders/colorspace.c`（LGPL-2.1-or-later）。保留许可在 `libplacebo-LICENSE`，逐文件来源及 SHA 见 `RendererCompatibility.json`。没有引入新 dylib 或修改任何 shader 权重。

颜色策略的适用范围、fallback、现有 `target-contrast` 在 legacy renderer 中的受限支持，以及验证边界见 `docs/RendererCompatibility.md`。这不是完整迁移 libplacebo renderer。

AI provider configuration, model catalogues and protocol references: [AI.md](AI.md), including the preserved AgentKernel MIT license.
