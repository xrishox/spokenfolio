// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "macos-tts-server",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "siri-tts-server", targets: ["SiriTTSServer"])
  ],
  dependencies: [
    // 1.31+ adopts APIs unavailable on the oldest supported macOS 15
    // point releases. Keep the HTTP stack deployable to the stated floor.
    .package(
      url: "https://github.com/swift-server/async-http-client.git",
      exact: "1.30.3"
    ),
    .package(
      url: "https://github.com/vapor/vapor.git",
      exact: "4.121.2"
    ),
    .package(
      url: "https://github.com/apple/swift-argument-parser.git",
      exact: "1.8.2"
    ),
  ],
  targets: [
    // Siri synthesis: private-framework bridge, worker processes and pool,
    // voice discovery, permission preflight, sentence splitting, encoders.
    // Never depends on Vapor.
    .target(name: "SiriTTSCore"),
    // EPUB parsing, narration extraction, audiobook pipeline, and M4B output.
    // Depends only on SiriTTSCore and system frameworks.
    .target(
      name: "AudiobookKit",
      dependencies: ["SiriTTSCore"]
    ),
    .executableTarget(
      name: "SiriTTSServer",
      dependencies: [
        "SiriTTSCore",
        "AudiobookKit",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Vapor", package: "vapor"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "SiriTTSCoreTests",
      dependencies: [.target(name: "SiriTTSCore")]
    ),
    .testTarget(
      name: "AudiobookKitTests",
      dependencies: [.target(name: "AudiobookKit")]
    ),
    .testTarget(
      name: "SiriTTSServerTests",
      dependencies: [
        .target(name: "SiriTTSServer"),
        .product(name: "XCTVapor", package: "vapor"),
      ]
    ),
  ]
)
