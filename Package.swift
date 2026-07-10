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
  ],
  targets: [
    .executableTarget(
      name: "SiriTTSServer",
      dependencies: [
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Vapor", package: "vapor"),
      ]
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
