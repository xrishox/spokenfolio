import Foundation

package enum ReadAloudASREngine: String, Codable, Sendable, CaseIterable {
  case apple
  case whisper
  /// No recognition at all: transcripts are fabricated from the synthesis
  /// timeline sidecar this app wrote while producing the audiobook.
  case synthesis
}

package struct ReadAloudWhisperModel: RawRepresentable, Codable, Sendable, Hashable,
  CaseIterable
{
  package let rawValue: String

  package static let allCases: [Self] = [
    "tiny", "tiny.en", "tiny-q5_1", "tiny.en-q5_1", "tiny-q8_0",
    "base", "base.en", "base-q5_1", "base.en-q5_1", "base-q8_0",
    "small", "small.en", "small-q5_1", "small.en-q5_1", "small-q8_0",
    "medium", "medium.en", "medium-q5_0", "medium.en-q5_0", "medium-q8_0",
    "large-v1", "large-v2", "large-v2-q5_0", "large-v2-q8_0",
    "large-v3", "large-v3-q5_0", "large-v3-turbo", "large-v3-turbo-q5_0",
    "large-v3-turbo-q8_0",
  ].map { Self(unchecked: $0) }

  package static let tiny = Self(unchecked: "tiny")
  package static let largeV3Turbo = Self(unchecked: "large-v3-turbo")

  package init?(rawValue: String) {
    guard Self.allCases.contains(where: { $0.rawValue == rawValue }) else { return nil }
    self.rawValue = rawValue
  }

  private init(unchecked rawValue: String) { self.rawValue = rawValue }

  package init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    guard let model = Self(rawValue: value) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "unsupported Whisper model"))
    }
    self = model
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

package struct ReadAloudASRSettings: Codable, Sendable, Equatable {
  package var engine: ReadAloudASREngine
  package var whisperModel: ReadAloudWhisperModel?

  package static let apple = Self(engine: .apple, whisperModel: nil)
  package static let synthesis = Self(engine: .synthesis, whisperModel: nil)
  package static let whisperTiny = Self(engine: .whisper, whisperModel: .tiny)
  package static let whisperTurbo = Self(engine: .whisper, whisperModel: .largeV3Turbo)

  package static func whisper(_ model: ReadAloudWhisperModel = .largeV3Turbo) -> Self {
    Self(engine: .whisper, whisperModel: model)
  }

  package func validate(language: String) throws {
    switch engine {
    case .apple:
      guard whisperModel == nil else {
        throw ReadAloudError.invalidRequest("a Whisper model cannot be used with Apple ASR")
      }
    case .synthesis:
      guard whisperModel == nil else {
        throw ReadAloudError.invalidRequest(
          "a Whisper model cannot be used with the synthesis timeline")
      }
    case .whisper:
      guard let whisperModel else {
        throw ReadAloudError.invalidRequest("Whisper ASR requires a model")
      }
      let languageCode = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
        .first.map(String.init) ?? ""
      if languageCode != "en", whisperModel.rawValue.contains(".en") {
        throw ReadAloudError.invalidRequest(
          "English-only Whisper models cannot transcribe a non-English publication")
      }
    }
  }
}

package enum ReadAloudStage: String, Codable, Sendable, CaseIterable {
  case preparing, processingAudio, transcribing, markingUp, aligning, verifying
}

package struct ReadAloudProgress: Sendable, Equatable {
  package var stage: ReadAloudStage
  package var stageFraction: Double?
  package var overallFraction: Double
  package var message: String
}

package struct ReadAloudRequest: Codable, Sendable, Equatable {
  package static let schemaVersion = 3
  package var schemaVersion = Self.schemaVersion
  package var epubPath: String
  package var audiobookPath: String
  package var outputPath: String
  package var workDirectory: String
  package var opusBitrateKbps: Int
  package var language: String
  package var asr: ReadAloudASRSettings
  /// Explicit synthesis-timeline sidecar location for the exact (no-ASR)
  /// engine. Managed jobs point this at the app-support timeline store; nil
  /// keeps the standalone-CLI derivation beside the audiobook.
  package var synthesisTimelinePath: String?
  package var overwrite: Bool
  package var expectedExistingSHA256: String?

  package init(
    epubPath: String, audiobookPath: String, outputPath: String, workDirectory: String,
    opusBitrateKbps: Int = 32, language: String = "en-US",
    asr: ReadAloudASRSettings = .apple, synthesisTimelinePath: String? = nil,
    overwrite: Bool = false, expectedExistingSHA256: String? = nil
  ) {
    self.epubPath = epubPath
    self.audiobookPath = audiobookPath
    self.outputPath = outputPath
    self.workDirectory = workDirectory
    self.opusBitrateKbps = opusBitrateKbps
    self.language = language
    self.asr = asr
    self.synthesisTimelinePath = synthesisTimelinePath
    self.overwrite = overwrite
    self.expectedExistingSHA256 = expectedExistingSHA256
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, epubPath, audiobookPath, outputPath, workDirectory
    case opusBitrateKbps, language, asr, whisperModel, synthesisTimelinePath
    case overwrite, expectedExistingSHA256
  }

  package init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    epubPath = try values.decode(String.self, forKey: .epubPath)
    audiobookPath = try values.decode(String.self, forKey: .audiobookPath)
    outputPath = try values.decode(String.self, forKey: .outputPath)
    workDirectory = try values.decode(String.self, forKey: .workDirectory)
    opusBitrateKbps = try values.decode(Int.self, forKey: .opusBitrateKbps)
    language = try values.decode(String.self, forKey: .language)
    synthesisTimelinePath = try values.decodeIfPresent(
      String.self, forKey: .synthesisTimelinePath)
    overwrite = try values.decode(Bool.self, forKey: .overwrite)
    expectedExistingSHA256 = try values.decodeIfPresent(
      String.self, forKey: .expectedExistingSHA256)
    if schemaVersion == 1 {
      let rawModel = try values.decode(String.self, forKey: .whisperModel)
      guard let model = ReadAloudWhisperModel(rawValue: rawModel) else {
        throw DecodingError.dataCorruptedError(
          forKey: .whisperModel, in: values, debugDescription: "unsupported Whisper model")
      }
      asr = .whisper(model)
    } else {
      asr = try values.decode(ReadAloudASRSettings.self, forKey: .asr)
    }
  }

  package func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(epubPath, forKey: .epubPath)
    try values.encode(audiobookPath, forKey: .audiobookPath)
    try values.encode(outputPath, forKey: .outputPath)
    try values.encode(workDirectory, forKey: .workDirectory)
    try values.encode(opusBitrateKbps, forKey: .opusBitrateKbps)
    try values.encode(language, forKey: .language)
    try values.encodeIfPresent(synthesisTimelinePath, forKey: .synthesisTimelinePath)
    try values.encode(overwrite, forKey: .overwrite)
    try values.encodeIfPresent(expectedExistingSHA256, forKey: .expectedExistingSHA256)
    if schemaVersion == 1 {
      try values.encode(asr.whisperModel?.rawValue ?? ReadAloudWhisperModel.tiny.rawValue,
        forKey: .whisperModel)
    } else {
      try values.encode(asr, forKey: .asr)
    }
  }

  package func validate() throws {
    guard (1...Self.schemaVersion).contains(schemaVersion) else {
      throw ReadAloudError.invalidRequest("unsupported schema version \(schemaVersion)")
    }
    guard [16, 32, 64, 96].contains(opusBitrateKbps) else {
      throw ReadAloudError.invalidRequest("Opus bitrate must be 16, 32, 64, or 96 kbps")
    }
    guard !epubPath.isEmpty, !audiobookPath.isEmpty, !outputPath.isEmpty,
      !workDirectory.isEmpty
    else { throw ReadAloudError.invalidRequest("all input and output paths are required") }
    let epub = URL(fileURLWithPath: epubPath).standardizedFileURL
    let audiobook = URL(fileURLWithPath: audiobookPath).standardizedFileURL
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL
    let work = URL(fileURLWithPath: workDirectory).standardizedFileURL
    guard epub.pathExtension.lowercased() == "epub",
      audiobook.pathExtension.lowercased() == "m4b",
      output.pathExtension.lowercased() == "epub",
      Set([epub, audiobook, output, work]).count == 4
    else { throw ReadAloudError.invalidRequest("input, output, and work paths are invalid") }
    guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      language.utf8.count <= 128
    else { throw ReadAloudError.invalidRequest("language is required") }
    try asr.validate(language: language)
    if let synthesisTimelinePath {
      guard asr.engine == .synthesis,
        !synthesisTimelinePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ReadAloudError.invalidRequest(
          "an explicit synthesis timeline requires the synthesis engine and a real path")
      }
    }
    if let expectedExistingSHA256 {
      guard overwrite, expectedExistingSHA256.count == 64,
        expectedExistingSHA256 == expectedExistingSHA256.lowercased(),
        expectedExistingSHA256.allSatisfy(\.isHexDigit)
      else {
        throw ReadAloudError.invalidRequest(
          "guarded replacement requires overwrite and a SHA-256 digest")
      }
    }
  }
}

package struct ReadAloudToolchain: Sendable, Equatable {
  package var stalign: URL
  package var ffmpeg: URL
  package var ffprobe: URL
  package var stalignVersion: String
  package var stalignSHA256: String

  package init(
    stalign: URL, ffmpeg: URL, ffprobe: URL,
    stalignVersion: String, stalignSHA256: String
  ) {
    self.stalign = stalign
    self.ffmpeg = ffmpeg
    self.ffprobe = ffprobe
    self.stalignVersion = stalignVersion
    self.stalignSHA256 = stalignSHA256
  }
}

package struct ReadAloudVerificationReport: Sendable, Equatable {
  package var entryCount: Int
  package var smilCount: Int
  package var audioCount: Int
  package var decodedAudioCount: Int
}

package enum ReadAloudError: Error, LocalizedError, Equatable {
  case invalidRequest(String)
  case missingTool(String)
  case unsupportedTool(String)
  case processFailed(String)
  case invalidArtifact(String)
  case outputExists(String)
  case outputChanged(String)
  case cancelled

  package var errorDescription: String? {
    switch self {
    case .invalidRequest(let value): "Invalid ReadAloud request: \(value)."
    case .missingTool(let value): "Missing ReadAloud tool: \(value)."
    case .unsupportedTool(let value): "Unsupported ReadAloud tool: \(value)."
    case .processFailed(let value): "ReadAloud tool failed: \(value)."
    case .invalidArtifact(let value): "Invalid ReadAloud artifact: \(value)."
    case .outputExists(let path): "ReadAloud output already exists: \(path)."
    case .outputChanged(let path):
      "ReadAloud output changed while processing and was not replaced: \(path)."
    case .cancelled: "ReadAloud creation was cancelled."
    }
  }
}
