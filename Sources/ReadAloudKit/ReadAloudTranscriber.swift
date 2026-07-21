import AVFoundation
import Darwin
import EPUBKit
import Foundation
import Speech

package struct ReadAloudTranscriptionJob: Sendable {
  package var processedAudio: URL
  package var transcriptions: URL
  package var sourceEPUB: URL
  package var language: String
  package var temporaryDirectory: URL
  package var environment: [String: String]
  /// Total decoded duration of the processed tracks, so whole-book external
  /// stages can scale their deadlines with the actual workload.
  package var totalAudioDuration: Double = 0
  /// The original audiobook and its staged-copy digest, so a transcriber
  /// that consumes synthesis-time artifacts can locate and digest-bind them.
  package var sourceAudiobook: URL?
  package var sourceAudiobookSHA256: String?
}

/// Deadlines for whole-book external stages scale with the audio the stage
/// must process, bounded on both ends: the floor keeps short books on the
/// historical 30-minute budget, and the ceiling still catches a hung tool.
/// (Measured: Whisper transcription of a 14-hour book exceeded the fixed
/// 30-minute deadline while making normal progress.)
package enum ReadAloudDeadlines {
  package static func wholeBookStage(totalAudioSeconds: Double) -> Duration {
    guard totalAudioSeconds.isFinite, totalAudioSeconds > 0 else { return .seconds(1_800) }
    return .seconds(min(max(1_800, totalAudioSeconds * 0.75 + 900), 43_200))
  }
}

package protocol ReadAloudTranscriber: Sendable {
  var identity: String { get }
  func transcribe(
    _ job: ReadAloudTranscriptionJob,
    progress: @escaping @Sendable (Double, String) -> Void
  ) async throws
}

package final class StalignWhisperTranscriber: ReadAloudTranscriber, @unchecked Sendable {
  package let identity: String
  private let model: ReadAloudWhisperModel
  private let tools: ReadAloudToolchain
  private let runner: ExternalProcessRunner

  package init(
    model: ReadAloudWhisperModel, tools: ReadAloudToolchain,
    runner: ExternalProcessRunner = .init()
  ) {
    self.model = model
    self.tools = tools
    self.runner = runner
    identity = "stalign-whisper:\(model.rawValue):\(tools.stalignVersion):\(tools.stalignSHA256)"
  }

  package func transcribe(
    _ job: ReadAloudTranscriptionJob,
    progress: @escaping @Sendable (Double, String) -> Void
  ) async throws {
    try FileManager.default.createDirectory(
      at: job.transcriptions, withIntermediateDirectories: true)
    let parser = ReadAloudToolProgress { progress($0, "Transcribing with Whisper") }
    let home = URL(fileURLWithPath: job.environment["HOME"] ?? "", isDirectory: true)
    let timeout = ReadAloudDeadlines.wholeBookStage(totalAudioSeconds: job.totalAudioDuration)
    let result = try await ReadAloudCacheLock.withLock(home: home) {
      try await self.runner.run(
        executable: self.tools.stalign,
        arguments: [
          "transcribe", "--parallel", "1", "--language", job.language,
          "--engine", "whisper.cpp", "--model", self.model.rawValue,
          "--no-progress", "--log-level", "info",
          job.processedAudio.path, job.transcriptions.path,
        ], environment: job.environment, timeout: timeout,
        onStderr: { parser.consume($0) })
    }
    try Task.checkCancellation()
    guard result.status == 0 else {
      throw ReadAloudError.processFailed(
        String(decoding: result.stderr.suffix(4_096), as: UTF8.self))
    }
    progress(1, "Whisper transcription complete")
  }
}

@available(macOS 26.0, *)
package final class AppleSpeechReadAloudTranscriber: ReadAloudTranscriber, @unchecked Sendable {
  // SpeechTranscriber, uncustomized — the measured optimum, not an oversight:
  // contextual strings are a no-op for this module (byte-identical output on
  // a 99-track book), and the DictationTranscriber + book-trained custom
  // language model path (v2/v3 experiments, never shipped) doubled raw name
  // hits but changed stalign's sentence alignment not at all while adding
  // homophone slips and possessive-splitting on prose. Version numbers are
  // never reused so resume fingerprints cannot collide across behaviors.
  package static let adapterVersion = 1
  package let identity: String
  private let tools: ReadAloudToolchain
  private let runner: ExternalProcessRunner

  package init(tools: ReadAloudToolchain, runner: ExternalProcessRunner = .init()) {
    self.tools = tools
    self.runner = runner
    identity = "apple-speech:\(Self.adapterVersion):\(ProcessInfo.processInfo.operatingSystemVersionString)"
  }

  package static func resolvedLocale(_ identifier: String) async -> Locale? {
    await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
  }

  package func transcribe(
    _ job: ReadAloudTranscriptionJob,
    progress: @escaping @Sendable (Double, String) -> Void
  ) async throws {
    guard let locale = await Self.resolvedLocale(job.language) else {
      throw ReadAloudError.unsupportedTool(
        "Apple Speech does not support locale \(job.language); choose Whisper ASR")
    }
    let assetModule = makeModule(locale: locale)
    switch await AssetInventory.status(forModules: [assetModule]) {
    case .unsupported:
      throw ReadAloudError.unsupportedTool(
        "Apple Speech does not support locale \(job.language); choose Whisper ASR")
    case .supported, .downloading:
      progress(0, "Installing Apple Speech model for \(locale.identifier)")
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [assetModule]) {
        try await request.downloadAndInstall()
      }
    case .installed: break
    @unknown default:
      throw ReadAloudError.unsupportedTool("Apple Speech returned an unknown asset status")
    }
    let acquiredReservation = try await AssetInventory.reserve(locale: locale)
    // `false` means this app already owns the reservation, not that allocation failed.
    // Only release reservations acquired by this operation so an existing app-wide
    // reservation is not disturbed.
    defer {
      if acquiredReservation {
        Task { _ = await AssetInventory.release(reservedLocale: locale) }
      }
    }

    let audioFiles = try Self.audioFiles(in: job.processedAudio)
    try FileManager.default.createDirectory(
      at: job.transcriptions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: job.temporaryDirectory, withIntermediateDirectories: true)
    let normalizer = try EPUBHeadingTranscriptNormalizer(sourceEPUB: job.sourceEPUB)
    let expectedStems = Set(audioFiles.map { $0.deletingPathExtension().lastPathComponent })
    try removeUnexpectedTranscripts(in: job.transcriptions, expectedStems: expectedStems)

    for (index, audio) in audioFiles.enumerated() {
      try Task.checkCancellation()
      let stem = audio.deletingPathExtension().lastPathComponent
      let destination = job.transcriptions.appendingPathComponent(stem + ".json")
      let duration = try await probeDuration(audio, environment: job.environment)
      if let existing = try? StalignTranscriptValidator.decode(destination),
        (try? StalignTranscriptValidator.validate(existing, audioDuration: duration)) != nil
      {
        progress(Double(index + 1) / Double(audioFiles.count), "Reused Apple transcript")
        continue
      }
      try? FileManager.default.removeItem(at: destination)
      let pcm = job.temporaryDirectory.appendingPathComponent("\(stem)-\(UUID().uuidString).wav")
      defer { try? FileManager.default.removeItem(at: pcm) }
      let decoded = try await runner.run(
        executable: tools.ffmpeg,
        arguments: [
          "-hide_banner", "-loglevel", "error", "-y", "-i", audio.path,
          "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", pcm.path,
        ], environment: job.environment)
      guard decoded.status == 0 else {
        throw ReadAloudError.processFailed("ffmpeg could not prepare audio for Apple Speech")
      }
      var transcript = try await transcribePCM(pcm, locale: locale)
      transcript = normalizer.normalize(transcript, audioDuration: duration).transcript
      try StalignTranscriptValidator.validate(transcript, audioDuration: duration)
      try atomicWrite(transcript, to: destination)
      progress(
        Double(index + 1) / Double(audioFiles.count),
        "Transcribed track \(index + 1) of \(audioFiles.count) with Apple Speech")
    }
  }

  private func makeModule(locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [],
      attributeOptions: [.audioTimeRange, .transcriptionConfidence])
  }

  private func transcribePCM(_ input: URL, locale: Locale) async throws -> StalignTranscript {
    let transcriber = makeModule(locale: locale)
    let analyzer = SpeechAnalyzer(
      modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
    let audioFile = try AVAudioFile(forReading: input)
    let collector = Task { () throws -> [StalignTimelineEntry] in
      var entries: [StalignTimelineEntry] = []
      for try await result in transcriber.results where result.isFinal {
        for run in result.text.runs {
          let text = String(result.text[run.range].characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { continue }
          guard let range = run.audioTimeRange else {
            throw ReadAloudError.invalidArtifact(
              "Apple Speech returned final text without audio timing")
          }
          let start = range.start.seconds
          let end = range.end.seconds
          guard start.isFinite, end.isFinite, end >= start else {
            throw ReadAloudError.invalidArtifact("Apple Speech returned invalid audio timing")
          }
          entries.append(
            .init(
              type: text.split(whereSeparator: \.isWhitespace).count > 1 ? "segment" : "word",
              text: text, startTime: start, endTime: end,
              confidence: run.transcriptionConfidence))
        }
      }
      return entries
    }
    return try await withTaskCancellationHandler {
      _ = try await analyzer.analyzeSequence(from: audioFile)
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      let entries = try await collector.value.sorted {
        ($0.startTime, $0.endTime) < ($1.startTime, $1.endTime)
      }
      return StalignTranscript(timedEntries: entries)
    } onCancel: {
      collector.cancel()
      Task { await analyzer.cancelAndFinishNow() }
    }
  }

  private func probeDuration(_ audio: URL, environment: [String: String]) async throws -> Double {
    let result = try await runner.run(
      executable: tools.ffprobe,
      arguments: [
        "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=duration",
        "-of", "json", audio.path,
      ], environment: environment, timeout: .seconds(60))
    guard result.status == 0,
      let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
      let streams = object["streams"] as? [[String: Any]], let stream = streams.first,
      let duration = Double(String(describing: stream["duration"] ?? "")), duration.isFinite,
      duration > 0
    else { throw ReadAloudError.invalidArtifact("processed audio duration is unavailable") }
    return duration
  }

  private static func audioFiles(in directory: URL) throws -> [URL] {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      .filter { $0.pathExtension.lowercased() == "mp4" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty, files.count <= StalignTranscriptValidator.maximumTrackCount else {
      throw ReadAloudError.invalidArtifact("processed audio track set is empty or too large")
    }
    for file in files {
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size > 0
      else { throw ReadAloudError.invalidArtifact("processed audio is not a regular file") }
    }
    return files
  }

  private func removeUnexpectedTranscripts(in directory: URL, expectedStems: Set<String>) throws {
    for file in try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: nil)
    where file.pathExtension.lowercased() == "json"
      && !expectedStems.contains(file.deletingPathExtension().lastPathComponent)
    {
      try FileManager.default.removeItem(at: file)
    }
  }

  private func atomicWrite(_ value: StalignTranscript, to destination: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let partial = destination.appendingPathExtension(UUID().uuidString + ".partial")
    defer { try? FileManager.default.removeItem(at: partial) }
    try encoder.encode(value).write(to: partial)
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
    } else {
      try FileManager.default.moveItem(at: partial, to: destination)
    }
  }
}

package final class ReadAloudCacheLock: @unchecked Sendable {
  private let descriptor: Int32

  private init(home: URL) throws {
    guard !home.path.isEmpty else {
      throw ReadAloudError.invalidRequest("shared stalign cache HOME is unavailable")
    }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    guard chmod(home.path, 0o700) == 0 else {
      throw ReadAloudError.processFailed("could not secure the shared Whisper cache")
    }
    let path = home.appendingPathComponent("transcription.lock").path
    descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw ReadAloudError.processFailed("could not open the shared Whisper cache lock")
    }
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }

  package static func withLock<T: Sendable>(
    home: URL, operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let lock = try ReadAloudCacheLock(home: home)
    while flock(lock.descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK else {
        throw ReadAloudError.processFailed("could not acquire the shared Whisper cache lock")
      }
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(250))
    }
    return try await operation()
  }
}

private final class ReadAloudToolProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var last = 0.0
  private let callback: @Sendable (Double) -> Void
  init(callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
  func consume(_ value: String) {
    let pattern = /Progress:\s*(\d{1,3})%/
    for match in value.matches(of: pattern) {
      guard let amount = Double(match.1), amount <= 100 else { continue }
      lock.withLock {
        let fraction = amount / 100
        guard fraction >= last else { return }
        last = fraction
        callback(fraction)
      }
    }
  }
}
