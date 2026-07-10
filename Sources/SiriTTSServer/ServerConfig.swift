import Foundation

struct ServerConfig: Codable, Sendable {
  var host: String
  var port: Int
  var defaultVoice: String?
  var maxWorkers: Int
  var maxQueuedRequests: Int
  var requestDeadlineSeconds: Double

  init(
    host: String = "0.0.0.0",
    port: Int = 8787,
    defaultVoice: String? = nil,
    maxWorkers: Int = 4,
    maxQueuedRequests: Int = 20,
    requestDeadlineSeconds: Double = 25
  ) {
    self.host = host
    self.port = port
    self.defaultVoice = defaultVoice
    self.maxWorkers = maxWorkers
    self.maxQueuedRequests = maxQueuedRequests
    self.requestDeadlineSeconds = requestDeadlineSeconds
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    host = try container.decodeIfPresent(String.self, forKey: .host) ?? "0.0.0.0"
    port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8787
    defaultVoice = try container.decodeIfPresent(String.self, forKey: .defaultVoice)
    maxWorkers = try container.decodeIfPresent(Int.self, forKey: .maxWorkers) ?? 4
    maxQueuedRequests =
      try container.decodeIfPresent(Int.self, forKey: .maxQueuedRequests) ?? 20
    requestDeadlineSeconds =
      try container.decodeIfPresent(Double.self, forKey: .requestDeadlineSeconds) ?? 25
  }

  static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws
    -> Self
  {
    let configURL: URL
    if let explicit = environment["SIRI_TTS_CONFIG"], !explicit.isEmpty {
      configURL = URL(fileURLWithPath: explicit)
    } else {
      configURL = defaultConfigURL
    }

    var config: Self
    if FileManager.default.fileExists(atPath: configURL.path) {
      config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: configURL))
    } else {
      config = Self()
    }

    if let host = environment["HTTP_HOST"], !host.isEmpty { config.host = host }
    if let raw = environment["HTTP_PORT"], let port = Int(raw) { config.port = port }
    try config.validate()
    return config
  }

  static var applicationSupportDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/com.xrishox.macos-tts-server", isDirectory: true)
  }

  static var defaultConfigURL: URL {
    applicationSupportDirectory.appendingPathComponent("config.json")
  }

  func validate() throws {
    guard !host.isEmpty else { throw ConfigurationError("host must not be empty") }
    guard (1...65_535).contains(port) else {
      throw ConfigurationError("port must be between 1 and 65535")
    }
    guard (1...4).contains(maxWorkers) else {
      throw ConfigurationError("maxWorkers must be between 1 and 4")
    }
    guard (0...20).contains(maxQueuedRequests) else {
      throw ConfigurationError("maxQueuedRequests must be between 0 and 20")
    }
    guard (1...120).contains(requestDeadlineSeconds) else {
      throw ConfigurationError("requestDeadlineSeconds must be between 1 and 120")
    }
  }
}

struct ConfigurationError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
