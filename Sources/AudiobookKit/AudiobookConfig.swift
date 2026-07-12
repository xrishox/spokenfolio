import Foundation
import SiriTTSCore

/// Audiobook defaults, stored as a nested `"audiobook"` object in the same
/// config.json the server uses. The server's decoder ignores the key; this
/// decoder reads only its subtree. Missing file, missing key, and partial
/// objects all fall back to defaults.
package struct AudiobookConfig: Codable, Sendable {
  package var defaultBitrateKbps: Int
  package var paragraphPauseSeconds: Double
  package var chapterPauseSeconds: Double
  package var announceTitles: Bool
  package var maxWorkers: Int
  package var defaultVoice: String?
  package var workDirectory: String?

  package init(
    defaultBitrateKbps: Int = 256,
    paragraphPauseSeconds: Double = 0.6,
    chapterPauseSeconds: Double = 1.75,
    announceTitles: Bool = true,
    maxWorkers: Int = 0,
    defaultVoice: String? = nil,
    workDirectory: String? = nil
  ) {
    self.defaultBitrateKbps = defaultBitrateKbps
    self.paragraphPauseSeconds = paragraphPauseSeconds
    self.chapterPauseSeconds = chapterPauseSeconds
    self.announceTitles = announceTitles
    self.maxWorkers = maxWorkers
    self.defaultVoice = defaultVoice
    self.workDirectory = workDirectory
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = AudiobookConfig()
    defaultBitrateKbps =
      try container.decodeIfPresent(Int.self, forKey: .defaultBitrateKbps)
      ?? defaults.defaultBitrateKbps
    paragraphPauseSeconds =
      try container.decodeIfPresent(Double.self, forKey: .paragraphPauseSeconds)
      ?? defaults.paragraphPauseSeconds
    chapterPauseSeconds =
      try container.decodeIfPresent(Double.self, forKey: .chapterPauseSeconds)
      ?? defaults.chapterPauseSeconds
    announceTitles =
      try container.decodeIfPresent(Bool.self, forKey: .announceTitles)
      ?? defaults.announceTitles
    maxWorkers =
      try container.decodeIfPresent(Int.self, forKey: .maxWorkers) ?? defaults.maxWorkers
    defaultVoice = try container.decodeIfPresent(String.self, forKey: .defaultVoice)
    workDirectory = try container.decodeIfPresent(String.self, forKey: .workDirectory)
  }

  package static let allowedBitratesKbps = [32, 64, 128, 256]

  /// Measured on M4 Max: throughput saturates the shared matrix units at
  /// ~8 concurrent workers (16.2× realtime) and gains nothing beyond; on
  /// smaller machines the performance-core count is the sensible bound.
  package static var autoMaxWorkers: Int {
    var cores: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0)
    return max(2, min(8, cores > 0 ? Int(cores) : 4))
  }

  /// The effective worker count: explicit value, or the hardware default.
  package var resolvedMaxWorkers: Int {
    maxWorkers > 0 ? maxWorkers : Self.autoMaxWorkers
  }

  package static var defaultConfigURL: URL {
    AppPaths.applicationSupportDirectory.appendingPathComponent("config.json")
  }

  package static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> AudiobookConfig {
    let configURL: URL
    if let explicit = environment["SIRI_TTS_CONFIG"], !explicit.isEmpty {
      configURL = URL(fileURLWithPath: explicit)
    } else {
      configURL = defaultConfigURL
    }
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      return AudiobookConfig()
    }
    struct Wrapper: Codable {
      var audiobook: AudiobookConfig?
    }
    let wrapper = try JSONDecoder().decode(Wrapper.self, from: Data(contentsOf: configURL))
    let config = wrapper.audiobook ?? AudiobookConfig()
    try config.validate()
    return config
  }

  package func validate() throws {
    guard Self.allowedBitratesKbps.contains(defaultBitrateKbps) else {
      throw ConfigurationError(
        "audiobook.defaultBitrateKbps must be one of "
          + Self.allowedBitratesKbps.map(String.init).joined(separator: ", "))
    }
    guard (0...10).contains(paragraphPauseSeconds) else {
      throw ConfigurationError("audiobook.paragraphPauseSeconds must be between 0 and 10")
    }
    guard (0...10).contains(chapterPauseSeconds) else {
      throw ConfigurationError("audiobook.chapterPauseSeconds must be between 0 and 10")
    }
    guard (0...16).contains(maxWorkers) else {
      throw ConfigurationError("audiobook.maxWorkers must be 0 (auto) or between 1 and 16")
    }
  }
}
