import CryptoKit
import Foundation

/// Fabricates stalign transcripts from the synthesis timeline sidecar this
/// app wrote while producing the audiobook. Entries use exact utterance,
/// independently synthesized-piece, or validated engine boundaries; the
/// independent quality ASR checks their content/timing before publication.
/// The sidecar is a versioned JSON contract with AudiobookKit
/// (`BookSynthesisTimeline`); ReadAloudKit mirrors the fields it consumes so
/// the dependency graph stays intact, and a cross-kit round-trip test pins
/// the contract.
///
/// Strictness: the sidecar is either passed explicitly (managed jobs read it
/// from the app-support timeline store) or derived beside the source
/// audiobook (the standalone CLI layout); its `m4bSHA256` must equal the
/// staged audiobook digest, its coverage must be complete, and the processed
/// track set must match the chapter set in count, order, and duration. Any
/// mismatch is a hard error — never a silent fallback to recognition.
package struct SynthesisTimelineTranscriber: ReadAloudTranscriber {
  package static let adapterVersion = 2

  struct Sidecar: Codable {
    struct Word: Codable {
      var text: String
      var startFrame: Int
      var endFrame: Int
    }
    struct Sentence: Codable {
      var text: String
      var startFrame: Int
      var endFrame: Int
      var derivation: String
      var kind: String
      var words: [Word]?
    }
    struct Chapter: Codable {
      var index: Int
      var title: String
      var startFrame: Int
      var presentedFrames: Int
      var contentOffsetFrames: Int
      /// Absent in sidecars written before the field existed; nil means the
      /// narrated-document set is unknown, not empty.
      var sourceDocuments: [String]?
      var sentences: [Sentence]
    }
    var schemaVersion: Int
    var m4bSHA256: String
    var sampleRate: Int
    var timelineCoverage: Double
    var chapters: [Chapter]
  }

  private let tools: ReadAloudToolchain
  private let runner: ExternalProcessRunner
  private let sidecarURL: URL
  private let sidecarSHA256: String

  package init(
    tools: ReadAloudToolchain, runner: ExternalProcessRunner, audiobook: URL,
    sidecar: URL? = nil
  ) throws {
    self.tools = tools
    self.runner = runner
    let url = sidecar ?? Self.derivedSidecarURL(for: audiobook)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ReadAloudError.invalidRequest(
        "no synthesis timeline for this audiobook — create the audiobook "
          + "with the timeline enabled, or choose a recognition engine")
    }
    self.sidecarURL = url
    var hasher = SHA256()
    hasher.update(data: try Data(contentsOf: url))
    self.sidecarSHA256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  package var identity: String {
    "synthesis-timeline:\(Self.adapterVersion):\(sidecarSHA256)"
  }

  /// The standalone-CLI layout: the sidecar lives beside the audiobook and
  /// shares its stem. Managed jobs pass an explicit store location instead.
  package static func derivedSidecarURL(for audiobook: URL) -> URL {
    audiobook.deletingPathExtension().appendingPathExtension("synthesis-timeline.json")
  }

  /// The exact set of spine documents the audiobook narrates, from a fully
  /// covered sidecar bound to `expectedAudiobookSHA256`. Returns nil — never
  /// a guess — when the sidecar is missing, unbound, partially covered, or
  /// predates the source-document field, so callers treat the narration set
  /// as unknown and skip search neutralization rather than misapply it.
  package static func narratedDocuments(
    audiobook: URL, expectedAudiobookSHA256: String, sidecar: URL? = nil
  ) -> Set<String>? {
    chapterSourceDocuments(
      audiobook: audiobook, expectedAudiobookSHA256: expectedAudiobookSHA256,
      sidecar: sidecar
    ).map { chapters in
      chapters.reduce(into: Set<String>()) { $0.formUnion($1) }
    }
  }

  /// Per-chapter narrated source documents in chapter order, under the same
  /// binding and coverage requirements as `narratedDocuments`. Chapter order
  /// equals sorted processed-track order, so callers can map a document to
  /// the exact tracks that narrate it.
  package static func chapterSourceDocuments(
    audiobook: URL, expectedAudiobookSHA256: String, sidecar: URL? = nil
  ) -> [[String]]? {
    let url = sidecar ?? derivedSidecarURL(for: audiobook)
    guard let data = try? Data(contentsOf: url),
      let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
      sidecar.m4bSHA256 == expectedAudiobookSHA256,
      sidecar.timelineCoverage >= 1
    else { return nil }
    var result: [[String]] = []
    for chapter in sidecar.chapters.sorted(by: { $0.index < $1.index }) {
      guard let documents = chapter.sourceDocuments else { return nil }
      result.append(documents)
    }
    return result
  }

  package func transcribe(
    _ job: ReadAloudTranscriptionJob,
    progress: @escaping @Sendable (Double, String) -> Void
  ) async throws {
    let sidecar = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: sidecarURL))
    guard sidecar.schemaVersion == 2 else {
      throw ReadAloudError.invalidArtifact(
        "unsupported synthesis timeline schema \(sidecar.schemaVersion)")
    }
    guard sidecar.timelineCoverage >= 1.0 else {
      throw ReadAloudError.invalidArtifact(
        "synthesis timeline covers only \(Int(sidecar.timelineCoverage * 100))% of chapters")
    }
    if let expected = job.sourceAudiobookSHA256, expected != sidecar.m4bSHA256 {
      throw ReadAloudError.invalidArtifact(
        "synthesis timeline is bound to a different audiobook (digest mismatch)")
    }
    let tracks = try FileManager.default.contentsOfDirectory(
      at: job.processedAudio, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension.lowercased() == "mp4" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard tracks.count == sidecar.chapters.count else {
      throw ReadAloudError.invalidArtifact(
        "processed tracks (\(tracks.count)) do not match timeline chapters "
          + "(\(sidecar.chapters.count))")
    }

    let sampleRate = Double(sidecar.sampleRate)
    for (index, track) in tracks.enumerated() {
      let chapter = sidecar.chapters[index]
      let trackDuration = try await probeDuration(track, environment: job.environment)
      let expectedDuration = Double(chapter.presentedFrames) / sampleRate
      guard abs(trackDuration - expectedDuration) <= Self.durationTolerance else {
        throw ReadAloudError.invalidArtifact(
          "track \(track.lastPathComponent) duration \(trackDuration) does not match "
            + "timeline chapter \(chapter.index) (\(expectedDuration))")
      }
      let contentOffset = Double(chapter.contentOffsetFrames) / sampleRate
      var entries: [StalignTimelineEntry] = []
      for sentence in chapter.sentences {
        // Word-granular entries when the engine reported words (matching
        // what recognition engines emit, which the audits expect);
        // otherwise one sentence segment.
        if let words = sentence.words, !words.isEmpty {
          for word in words {
            let start = Double(word.startFrame) / sampleRate + contentOffset
            let end = Double(word.endFrame) / sampleRate + contentOffset
            guard end > start, !word.text.isEmpty else { continue }
            entries.append(
              StalignTimelineEntry(
                type: word.text.contains(" ") ? "segment" : "word",
                text: word.text,
                startTime: min(start, trackDuration),
                endTime: min(end, trackDuration + 0.5),
                confidence: 1.0))
          }
          continue
        }
        let start = Double(sentence.startFrame) / sampleRate + contentOffset
        let end = Double(sentence.endFrame) / sampleRate + contentOffset
        guard end > start, !sentence.text.isEmpty else { continue }
        entries.append(
          StalignTimelineEntry(
            type: sentence.text.contains(" ") ? "segment" : "word",
            text: sentence.text,
            startTime: min(start, trackDuration),
            endTime: min(end, trackDuration + 0.5),
            confidence: 1.0))
      }
      guard !entries.isEmpty else {
        throw ReadAloudError.invalidArtifact(
          "timeline chapter \(chapter.index) has no speakable sentences")
      }
      let transcript = StalignTranscript(timedEntries: entries)
      try StalignTranscriptValidator.validate(
        transcript, audioDuration: trackDuration, enforceDurationCeiling: true)
      let stem = track.deletingPathExtension().lastPathComponent
      let output = job.transcriptions.appendingPathComponent("\(stem).json")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(transcript).write(to: output, options: .atomic)
      progress(Double(index + 1) / Double(tracks.count), "Timeline \(index + 1)/\(tracks.count)")
    }
    guard let audiobookSHA256 = job.sourceAudiobookSHA256 else {
      throw ReadAloudError.invalidArtifact(
        "synthesis transcript cannot be bound without the audiobook digest")
    }
    try TranscriptBindingManifest.write(
      processedAudio: job.processedAudio, transcriptions: job.transcriptions,
      sourceAudiobookSHA256: audiobookSHA256,
      transcriptionFingerprint: identity)
  }

  /// Chapter boundaries land on AAC packet edges, so a track can differ
  /// from the timeline by up to two packets plus the codec's own rounding.
  package static let durationTolerance = 0.25 + 3.0 * 1_024.0 / 48_000.0

  private func probeDuration(_ audio: URL, environment: [String: String]) async throws -> Double {
    let probe = try await runner.run(
      executable: tools.ffprobe,
      arguments: [
        "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=duration",
        "-of", "json", audio.path,
      ], environment: environment, timeout: .seconds(60))
    guard probe.status == 0,
      let object = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
      let streams = object["streams"] as? [[String: Any]], let stream = streams.first,
      let duration = Double(String(describing: stream["duration"] ?? "")), duration.isFinite,
      duration > 0
    else { throw ReadAloudError.invalidArtifact("processed audio duration is unavailable") }
    return duration
  }
}
