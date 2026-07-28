import Foundation

package struct AudiobookConfigurationError: Error, LocalizedError {
  package let message: String
  package init(_ message: String) { self.message = message }
  package var errorDescription: String? { message }
}

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

  /// Application-wide selection ceiling for installed Siri. Models may
  /// advertise a lower hard maximum; Siri Expressive production uses one.
  package static let maximumWorkers = 8

  /// Hardware default. Eight matches the measured plateau above; on smaller
  /// machines the performance-core count is the sensible bound.
  package static var autoMaxWorkers: Int {
    var cores: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0)
    return max(2, min(8, cores > 0 ? Int(cores) : 4))
  }

  /// Resolves worker policy in descending authority: an explicit command/job
  /// value, configured `audiobook.maxWorkers`, the selected model's measured
  /// recommendation, then the hardware default.
  package func resolvedMaxWorkers(explicit: Int?, recommended: Int?) -> Int {
    explicit ?? (maxWorkers > 0 ? maxWorkers : recommended ?? Self.autoMaxWorkers)
  }

  /// The effective configured count when no model-specific recommendation is
  /// available. Existing callers that have a model should use the method above.
  package var resolvedMaxWorkers: Int {
    resolvedMaxWorkers(explicit: nil, recommended: nil)
  }

  package func validate() throws {
    guard Self.allowedBitratesKbps.contains(defaultBitrateKbps) else {
      throw AudiobookConfigurationError(
        "audiobook.defaultBitrateKbps must be one of "
          + Self.allowedBitratesKbps.map(String.init).joined(separator: ", "))
    }
    guard (0...10).contains(paragraphPauseSeconds) else {
      throw AudiobookConfigurationError("audiobook.paragraphPauseSeconds must be between 0 and 10")
    }
    guard (0...10).contains(chapterPauseSeconds) else {
      throw AudiobookConfigurationError("audiobook.chapterPauseSeconds must be between 0 and 10")
    }
    guard (0...Self.maximumWorkers).contains(maxWorkers) else {
      throw AudiobookConfigurationError(
        "audiobook.maxWorkers must be 0 (auto) or between 1 and \(Self.maximumWorkers)")
    }
  }
}
