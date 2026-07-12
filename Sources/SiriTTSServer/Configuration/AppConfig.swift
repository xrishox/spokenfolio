import AudiobookKit
import Foundation

struct ConfigurationError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

enum AppPaths {
  static var applicationSupportDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/com.xrishox.macos-tts-server", isDirectory: true)
  }

  static var configURL: URL { applicationSupportDirectory.appendingPathComponent("config.json") }
  static var audiobookWorkRoot: URL {
    applicationSupportDirectory.appendingPathComponent("audiobook-jobs", isDirectory: true)
  }
}

struct AppConfig: Sendable {
  var server: ServerConfig
  var audiobook: AudiobookConfig

  static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AppConfig {
    let url = environment["SIRI_TTS_CONFIG"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? AppPaths.configURL
    var server = ServerConfig()
    var audiobook = AudiobookConfig()
    if FileManager.default.fileExists(atPath: url.path) {
      let data = try Data(contentsOf: url)
      server = try JSONDecoder().decode(ServerConfig.self, from: data)
      struct Wrapper: Decodable { let audiobook: AudiobookConfig? }
      audiobook = try JSONDecoder().decode(Wrapper.self, from: data).audiobook ?? AudiobookConfig()
    }
    try server.applyEnvironment(environment)
    try server.validate()
    try audiobook.validate()
    return AppConfig(server: server, audiobook: audiobook)
  }
}
