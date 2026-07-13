import Foundation

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
  package static let schemaVersion = 1
  package var schemaVersion = Self.schemaVersion
  package var epubPath: String
  package var audiobookPath: String
  package var outputPath: String
  package var workDirectory: String
  package var opusBitrateKbps: Int
  package var language: String
  package var whisperModel: String
  package var overwrite: Bool

  package init(
    epubPath: String, audiobookPath: String, outputPath: String, workDirectory: String,
    opusBitrateKbps: Int = 32, language: String = "en-US", whisperModel: String = "tiny",
    overwrite: Bool = false
  ) {
    self.epubPath = epubPath
    self.audiobookPath = audiobookPath
    self.outputPath = outputPath
    self.workDirectory = workDirectory
    self.opusBitrateKbps = opusBitrateKbps
    self.language = language
    self.whisperModel = whisperModel
    self.overwrite = overwrite
  }

  package func validate() throws {
    guard schemaVersion == Self.schemaVersion else {
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
      !whisperModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw ReadAloudError.invalidRequest("language and Whisper model are required") }
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
  case cancelled

  package var errorDescription: String? {
    switch self {
    case .invalidRequest(let value): "Invalid ReadAloud request: \(value)."
    case .missingTool(let value): "Missing ReadAloud tool: \(value)."
    case .unsupportedTool(let value): "Unsupported ReadAloud tool: \(value)."
    case .processFailed(let value): "ReadAloud tool failed: \(value)."
    case .invalidArtifact(let value): "Invalid ReadAloud artifact: \(value)."
    case .outputExists(let path): "ReadAloud output already exists: \(path)."
    case .cancelled: "ReadAloud creation was cancelled."
    }
  }
}
