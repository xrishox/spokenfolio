import AudiobookKit
import Foundation

struct ConfigurationError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

enum AppPaths {
  static var applicationSupportDirectory: URL {
    AppIdentity.applicationSupportDirectory
  }

  static var configURL: URL { applicationSupportDirectory.appendingPathComponent("config.json") }
  static var audiobookWorkRoot: URL {
    applicationSupportDirectory.appendingPathComponent("audiobook-jobs", isDirectory: true)
  }
  static var productionJobRoot: URL {
    applicationSupportDirectory.appendingPathComponent("production-jobs", isDirectory: true)
  }
  static var bookCatalogRoot: URL {
    applicationSupportDirectory.appendingPathComponent("book-catalog", isDirectory: true)
  }
  static var studioSettingsURL: URL {
    applicationSupportDirectory.appendingPathComponent("studio-settings.json")
  }
  static var schedulerStateURL: URL {
    applicationSupportDirectory.appendingPathComponent("scheduler.json")
  }
  static var schedulerLockURL: URL {
    applicationSupportDirectory.appendingPathComponent("scheduler.lock")
  }
  static var studioExecutionLockURL: URL {
    applicationSupportDirectory.appendingPathComponent("studio-execution.lock")
  }
  static var readAloudToolDirectory: URL {
    applicationSupportDirectory.appendingPathComponent("tools/readaloud", isDirectory: true)
  }
  static var managedStalignURL: URL {
    readAloudToolDirectory.appendingPathComponent("stalign")
  }
}

struct AppConfig: Sendable {
  var server: ServerConfig
  var audiobook: AudiobookConfig

  static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AppConfig {
    let url =
      environment["SPOKENFOLIO_CONFIG"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
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
