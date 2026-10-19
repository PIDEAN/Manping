import Foundation

/// One open-source project Manping took code, resources or libraries from (or, in the
/// `reference` group, only ideas). The single source for 设置 › 致谢, the About panel and the
/// README's 致谢 section; `AcknowledgementsTests` keeps the README in step with it.
public struct Acknowledgement: Sendable, Equatable, Identifiable {
  public enum Group: String, CaseIterable, Sendable {
    case original, playback, shaders, swift, assets, reference
    public var title: String {
      switch self {
      case .original: "原版与协议"
      case .playback: "播放与渲染"
      case .shaders: "画面增强着色器"
      case .swift: "Swift 包"
      case .assets: "资源与数据"
      case .reference: "参考与启发"
      }
    }
  }

  public let name: String
  public let author: String
  /// Empty when the project states none (references only).
  public let license: String
  public let url: String
  public let contribution: String
  public let group: Group
  public var id: String { name }

  public init(name: String, author: String, license: String, url: String, contribution: String, group: Group) {
    self.name = name; self.author = author; self.license = license
    self.url = url; self.contribution = contribution; self.group = group
  }
}

public enum Acknowledgements {
  /// In display order; Bili.Copilot first.
  public static let all: [Acknowledgement] = [
    // MARK: 原版与协议
    .init(name: "Bili.Copilot", author: "Richasy", license: "GPL-3.0", url: "https://github.com/Richasy/Bili.Copilot",
      contribution: "满屏由哔哩助理 Windows 版移植而来：界面结构与功能对照、AI 提示词原文、画面增强着色器资源包、用户等级与大会员图标。本项目因此采用 GPL-3.0。",
      group: .original),
    .init(name: "bili-kernel", author: "Richasy", license: "GPL-3.0", url: "https://github.com/Richasy/bili-kernel",
      contribution: "22 个 gRPC 协议定义与接口适配，以及登录与接口参数。", group: .original),
    .init(name: "agent-kernel", author: "Richasy", license: "MIT", url: "https://github.com/Richasy/agent-kernel",
      contribution: "AI 服务的配置字段、默认端点、预置模型目录与百度千帆签名。", group: .original),
    .init(name: "Bili CDN Switcher", author: "Bili CDN Switcher contributors", license: "MIT",
      url: "https://github.com/liiliiliil/bili-cdn-switcher",
      contribution: "CDN 候选节点、两阶段测速与卡顿判定，用 Swift 重写。", group: .original),

    // MARK: 播放与渲染
    .init(name: "mpv", author: "mpv contributors", license: "GPL-2.0-or-later / LGPL", url: "https://mpv.io",
      contribution: "播放核心，本项目打补丁构建的 libmpv 0.41.0。", group: .playback),
    .init(name: "FFmpeg", author: "FFmpeg developers", license: "GPL-3.0-or-later 构建", url: "https://ffmpeg.org",
      contribution: "解码、封装与下载合并。", group: .playback),
    .init(name: "libplacebo", author: "VideoLAN", license: "LGPL-2.1-or-later", url: "https://code.videolan.org/videolan/libplacebo",
      contribution: "GPU 渲染与色彩管理。", group: .playback),
    .init(name: "随附动态库", author: "各自作者", license: "各自许可", url: "https://github.com/PIDEAN/Manping/tree/main/ThirdPartyNotices/Libraries",
      contribution: "其余随附的动态库：" + bundledLibraries.joined(separator: "、") + "。许可全文见 ThirdPartyNotices/Libraries。",
      group: .playback),

    // MARK: 画面增强着色器
    .init(name: "Anime4K", author: "bloc97", license: "MIT / 部分文件为公有领域声明", url: "https://github.com/bloc97/Anime4K",
      contribution: "动画超分与降噪着色器，来自 Bili.Copilot 资源包。", group: .shaders),
    .init(name: "ArtCNN", author: "Artoriuz", license: "MIT；Ani4Kv2 权重由 Sirosky 训练，CC BY-NC 4.0", url: "https://github.com/Artoriuz/ArtCNN",
      contribution: "基于神经网络的超分着色器，来自 Bili.Copilot 资源包。", group: .shaders),
    .init(name: "RAVU 与 nnedi3 着色器", author: "bjin", license: "LGPL-3.0", url: "https://github.com/bjin/mpv-prescalers",
      contribution: "RAVU 与 nnedi3 预放大着色器，来自 Bili.Copilot 资源包。", group: .shaders),
    .init(name: "FSRCNNX、KrigBilateral、SSimSuperRes、SSimDownscaler", author: "igv、Shiandow", license: "FSRCNNX 见文件头；其余 LGPL-3.0-or-later", url: "https://github.com/igv",
      contribution: "FSRCNNX 超分（igv）；KrigBilateral 色度重建、SSimSuperRes 与 SSimDownscaler 缩放（Shiandow），来自 Bili.Copilot 资源包。", group: .shaders),
    .init(name: "adaptive-sharpen", author: "bacondither", license: "见文件头", url: "https://gist.github.com/bacondither",
      contribution: "自适应锐化着色器，来自 Bili.Copilot 资源包。", group: .shaders),

    // MARK: Swift 包
    .init(name: "grpc-swift", author: "gRPC authors", license: "Apache-2.0", url: "https://github.com/grpc/grpc-swift-2",
      contribution: "gRPC 客户端（grpc-swift-2、grpc-swift-nio-transport、grpc-swift-protobuf）。", group: .swift),
    .init(name: "swift-protobuf", author: "Apple", license: "Apache-2.0", url: "https://github.com/apple/swift-protobuf",
      contribution: "Protocol Buffers 的编解码。", group: .swift),
    .init(name: "SwiftNIO 系列", author: "Apple", license: "Apache-2.0", url: "https://github.com/apple/swift-nio",
      contribution: "网络层：swift-nio、nio-http2、nio-ssl、nio-extras、nio-transport-services。", group: .swift),
    .init(name: "Swift 基础库", author: "Apple、Swift Server Workgroup", license: "Apache-2.0", url: "https://github.com/apple",
      contribution: "swift-crypto、swift-certificates、swift-asn1、swift-log、swift-collections、swift-algorithms、swift-async-algorithms、swift-atomics、swift-numerics、swift-system、swift-http-types、swift-http-structured-headers，以及 swift-service-lifecycle。",
      group: .swift),

    // MARK: 资源与数据
    .init(name: "LobeHub Icons", author: "LobeHub", license: "MIT", url: "https://github.com/lobehub/lobe-icons",
      contribution: "AI 服务图标；各标识归其商标所有者。", group: .assets),
    .init(name: "Protocol Buffers any.proto", author: "Google", license: "BSD-3-Clause", url: "https://github.com/protocolbuffers/protobuf",
      contribution: "随协议定义附带的 any.proto。", group: .assets),
    .init(name: "Mozilla CA 证书包", author: "Mozilla", license: "MPL-2.0", url: "https://curl.se/docs/caextract.html",
      contribution: "经 Homebrew ca-certificates 取得的根证书，供外部命令校验连接。", group: .assets),

    // MARK: 参考与启发（未采用代码）
    .init(name: "bilibili-API-collect", author: "SocialSisterYi", license: "", url: "https://github.com/SocialSisterYi/bilibili-API-collect",
      contribution: "参考：接口文档。", group: .reference),
    .init(name: "winui-kernel", author: "Richasy", license: "", url: "https://github.com/Richasy/winui-kernel",
      contribution: "参考：AI 设置的配置结构。仓库未附许可证，仅参考结构，未复制代码。", group: .reference),
    .init(name: "IINA", author: "", license: "", url: "https://iina.io",
      contribution: "参考：Mac 播放器的交互。", group: .reference),
    .init(name: "PiliPlus / PiliPala", author: "", license: "", url: "https://github.com/bggRGjQaUbCoE/PiliPlus",
      contribution: "参考：跳过片头片尾、屏蔽等思路。", group: .reference),
    .init(name: "Bilibili-Evolved", author: "the1812", license: "", url: "https://github.com/the1812/Bilibili-Evolved",
      contribution: "参考：高能进度条。", group: .reference),
    .init(name: "BBDown", author: "nilaoda", license: "", url: "https://github.com/nilaoda/BBDown",
      contribution: "参考：外部下载命令格式。", group: .reference),
  ]

  /// The dynamic libraries shipped beside FFmpeg, mpv and libplacebo
  /// (ThirdPartyNotices/Libraries/README.md).
  static let bundledLibraries = [
    "dav1d", "fontconfig", "FreeType", "FriBidi", "gettext", "GLib", "Graphite2", "HarfBuzz", "libjpeg-turbo", "LAME",
    "libass", "libbluray", "libpng", "libsamplerate", "libudfread", "libunibreak", "libvmaf", "libvpx", "Little CMS",
    "LuaJIT", "mpg123", "MuJS", "OpenSSL", "Opus", "PCRE2", "Rubber Band", "shaderc", "SVT-AV1", "uchardet",
    "Vulkan Loader", "x264", "x265", "xz", "zimg",
  ]

  public static func entries(in group: Acknowledgement.Group) -> [Acknowledgement] { all.filter { $0.group == group } }
}
