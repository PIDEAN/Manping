// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Manping",
  platforms: [.macOS("27.0")],
  products: [.executable(name: "Manping", targets: ["ManpingApp"])],
  dependencies: [
    .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.3"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.1"),
    .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    // Explicit test products below exercise a raw HTTP/2 failure using the same NIOTS pipeline.
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.46.0"),
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
  ],
  targets: [
    .target(
      name: "BiliProtocol",
      dependencies: [
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ]),
    .target(
      name: "CMpv", publicHeadersPath: "include", linkerSettings: [.linkedFramework("OpenGL")]),
    .systemLibrary(name: "CSQLite"),
    .target(
      name: "ManpingCore",
      dependencies: [
        "CMpv", "CSQLite", "BiliProtocol",
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(
          name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      linkerSettings: [.linkedFramework("Security")]),
    .executableTarget(
      name: "ManpingApp", dependencies: ["ManpingCore", "CMpv"], resources: [.copy("Resources/Shaders"), .copy("Resources/StoreLogo.png"), .copy("Resources/MenuBarIcon.png"), .copy("Resources/Level"), .copy("Resources/vip.png"), .copy("Resources/AIProviders")],
      linkerSettings: [
        .linkedFramework("AppKit"), .linkedFramework("MetalKit"), .linkedFramework("OpenGL"),
      ]),
    .testTarget(
      name: "ManpingCoreTests",
      dependencies: [
        "ManpingCore", "BiliProtocol",
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(
          name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP2", package: "swift-nio-http2"),
        .product(name: "NIOHPACK", package: "swift-nio-http2"),
        .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
      ], resources: [.copy("Fixtures/RPC")]),
  ],
  swiftLanguageModes: [.v6]
)
