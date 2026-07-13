// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "spokenfolio",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "spokenfolio", targets: ["SpokenFolioApp"]),
    .executable(name: "siri-tts-bench", targets: ["SiriTTSBench"]),
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
    // Engine-neutral speech contracts, text segmentation, PCM normalization,
    // and complete in-memory response encoders.
    .target(name: "TTSKit"),
    .target(name: "PublicationKit"),
    // Durable, process-independent production job state. Deliberately has
    // no dependency on a specific publication, speech engine, or UI.
    .target(name: "BookJobKit", dependencies: ["PublicationKit"]),
    .target(name: "EPUBKit", dependencies: ["PublicationKit"]),
    .target(
      name: "ReadAloudKit",
      dependencies: ["PublicationKit", "EPUBKit"]
    ),
    .target(name: "StorytellerKit", dependencies: ["PublicationKit"]),
    // Siri synthesis: private-framework bridge, worker processes and pool,
    // voice discovery, permission preflight, and the TTSKit backend adapter.
    // Never depends on Vapor.
    .target(name: "SiriTTSCore", dependencies: ["TTSKit"]),
    // Source-neutral narration planning, synthesis/resume, and M4B output.
    // It deliberately knows neither EPUB nor Siri.
    .target(
      name: "AudiobookKit",
      dependencies: ["TTSKit", "PublicationKit"]
    ),
    .executableTarget(
      name: "SpokenFolioApp",
      dependencies: [
        "SiriTTSCore",
        "TTSKit",
        "AudiobookKit",
        "PublicationKit",
        "EPUBKit",
        "BookJobKit",
        "ReadAloudKit",
        "StorytellerKit",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Vapor", package: "vapor"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "SiriTTSBench",
      dependencies: [
        "TTSKit",
        "SiriTTSCore",
        "PublicationKit",
        "EPUBKit",
        "AudiobookKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "TTSKitTests",
      dependencies: [.target(name: "TTSKit")]
    ),
    .testTarget(
      name: "SiriTTSCoreTests",
      dependencies: [.target(name: "SiriTTSCore"), .target(name: "TTSKit")]
    ),
    .testTarget(
      name: "AudiobookKitTests",
      dependencies: [
        .target(name: "AudiobookKit"),
        .target(name: "EPUBKit"),
        .target(name: "PublicationKit"),
      ]
    ),
    .testTarget(
      name: "BookJobKitTests",
      dependencies: [.target(name: "BookJobKit")]
    ),
    .testTarget(
      name: "ReadAloudKitTests",
      dependencies: [.target(name: "ReadAloudKit")]
    ),
    .testTarget(
      name: "StorytellerKitTests",
      dependencies: [.target(name: "StorytellerKit")]
    ),
    .testTarget(
      name: "SpokenFolioAppTests",
      dependencies: [
        .target(name: "SpokenFolioApp"),
        .product(name: "XCTVapor", package: "vapor"),
      ]
    ),
  ]
)
