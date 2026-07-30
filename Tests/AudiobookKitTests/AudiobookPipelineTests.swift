import XCTest
import PublicationKit
import TTSKit

@testable import AudiobookKit

private func testRuntimeProvenance(
  voiceID: String = "v", resourceRevision: String? = nil
) -> TTSRuntimeProvenance {
  try! TTSRuntimeProvenance(
    backendID: TTSBackendID(rawValue: "siri"), modelID: "siri-private",
    voiceID: voiceID,
    operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
    frameworkIdentifier: "test.framework", frameworkVersion: "1",
    resourceIdentity: "test-resource", resourceRevision: resourceRevision)
}

// MARK: - Chapter artifact container

final class ChapterArtifactTests: XCTestCase {
  private let settings = AACEncodingSettings(bitRate: 64_000)
  private let fingerprint = Data(repeating: 0xAB, count: 32)

  private func makeArtifact(packets: [Data]) throws -> M4BChapterArtifact {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("segment-\(UUID().uuidString).aacseg")
    let writer = try ChapterSegmentWriter(url: url, settings: settings, fingerprint: fingerprint)
    for packet in packets { try writer.appendPacket(packet) }
    // Priming must stay plausible for the packet count (validate enforces
    // leading+trailing < packets × 1024).
    return try writer.finalize(
      leadingFrames: 1_024, trailingFrames: 500, audioSpecificConfig: Data([0x11, 0x88]))
  }

  func testRoundTripValidates() throws {
    let artifact = try makeArtifact(packets: [Data([1, 2, 3]), Data([4, 5])])
    defer { try? FileManager.default.removeItem(at: artifact.url) }

    let validated = try ChapterSegment.validate(
      url: artifact.url, settings: settings, fingerprint: fingerprint)
    XCTAssertEqual(validated.packetCount, 2)
    XCTAssertEqual(validated.leadingFrames, 1_024)
    XCTAssertEqual(validated.trailingFrames, 500)
    XCTAssertEqual(validated.audioSpecificConfig, Data([0x11, 0x88]))

    var collected: [Data] = []
    try ChapterSegment.forEachPacket(in: validated) { collected.append($0) }
    XCTAssertEqual(collected, [Data([1, 2, 3]), Data([4, 5])])
    XCTAssertEqual(try ChapterSegment.packetSizes(of: validated), [3, 2])
  }

  func testCorruptionMatrix() throws {
    let artifact = try makeArtifact(packets: [Data(repeating: 7, count: 100)])
    defer { try? FileManager.default.removeItem(at: artifact.url) }
    let original = try Data(contentsOf: artifact.url)

    // Truncation loses the end marker.
    try original.prefix(original.count - 3).write(to: artifact.url)
    XCTAssertThrowsError(
      try ChapterSegment.validate(url: artifact.url, settings: settings, fingerprint: fingerprint))

    // A flipped payload byte fails the checksum.
    var corrupted = original
    corrupted[ChapterSegment.headerLength + 10] ^= 0xFF
    try corrupted.write(to: artifact.url)
    XCTAssertThrowsError(
      try ChapterSegment.validate(url: artifact.url, settings: settings, fingerprint: fingerprint)
    ) { error in
      guard case AudiobookAudioError.artifactCorrupt = error else {
        return XCTFail("unexpected: \(error)")
      }
    }

    // Hostile trailer integers must throw, never trap: payloadByteCount with
    // the top bit set (offset 12 past the trailer start = 4 magic + 8 count),
    // an unexpected framesPerPacket (header offset 20), and priming frames
    // larger than the chapter (leadingFrames at trailer offset 20).
    let trailerLength = Int(
      original.suffix(8).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        .littleEndian)
    let trailerStart = original.count - trailerLength

    var hostilePayload = original
    hostilePayload[trailerStart + 12 + 7] |= 0x80
    try hostilePayload.write(to: artifact.url)
    XCTAssertThrowsError(
      try ChapterSegment.validate(url: artifact.url, settings: settings, fingerprint: fingerprint))

    var hostileFrames = original
    hostileFrames[20] = 0
    try hostileFrames.write(to: artifact.url)
    XCTAssertThrowsError(
      try ChapterSegment.validate(url: artifact.url, settings: settings, fingerprint: fingerprint))

    var hostilePriming = original
    hostilePriming[trailerStart + 20] = 0xFF
    hostilePriming[trailerStart + 21] = 0xFF
    hostilePriming[trailerStart + 22] = 0xFF
    hostilePriming[trailerStart + 23] = 0x7F
    try hostilePriming.write(to: artifact.url)
    XCTAssertThrowsError(
      try ChapterSegment.validate(url: artifact.url, settings: settings, fingerprint: fingerprint))

    // A different fingerprint (changed job inputs) is a settings mismatch.
    try original.write(to: artifact.url)
    XCTAssertThrowsError(
      try ChapterSegment.validate(
        url: artifact.url, settings: settings, fingerprint: Data(repeating: 1, count: 32))
    ) { error in
      guard case AudiobookAudioError.artifactSettingsMismatch = error else {
        return XCTFail("unexpected: \(error)")
      }
    }

    // Different bitrate settings are a mismatch too.
    XCTAssertThrowsError(
      try ChapterSegment.validate(
        url: artifact.url, settings: AACEncodingSettings(bitRate: 128_000),
        fingerprint: fingerprint))
  }

  func testEmptyChapterIsRejected() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("segment-\(UUID().uuidString).aacseg")
    let writer = try ChapterSegmentWriter(url: url, settings: settings, fingerprint: fingerprint)
    XCTAssertThrowsError(
      try writer.finalize(leadingFrames: 0, trailingFrames: 0, audioSpecificConfig: Data())
    ) { error in
      guard case AudiobookAudioError.emptyChapter = error else {
        return XCTFail("unexpected: \(error)")
      }
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: url.path), "no artifact for an empty chapter")
  }
}

// MARK: - Streaming encoder

final class AACChapterEncoderTests: XCTestCase {
  private func sinePCM(seconds: Double, frequency: Double = 440) -> Data {
    let frames = Int(48_000 * seconds)
    var data = Data(capacity: frames * 2)
    for frame in 0..<frames {
      var value = Int16(sin(2 * .pi * frequency * Double(frame) / 48_000) * 12_000)
        .littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
  }

  /// Chunk boundaries must not change the encoded stream: the whole point of
  /// the streaming encoder is equivalence with a single-buffer encode.
  func testChunkedEncodeMatchesSingleAppend() throws {
    let pcm = sinePCM(seconds: 1.5)
    let settings = AACEncodingSettings(bitRate: 64_000)
    let fingerprint = Data(repeating: 3, count: 32)

    func encode(chunkSize: Int?) throws -> (M4BChapterArtifact, [Data]) {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("enc-\(UUID().uuidString).aacseg")
      let encoder = try AACChapterEncoder(
        artifactURL: url, settings: settings, fingerprint: fingerprint)
      if let chunkSize {
        var offset = 0
        while offset < pcm.count {
          let end = min(offset + chunkSize, pcm.count)
          try encoder.append(pcm16: pcm.subdata(in: offset..<end))
          offset = end
        }
      } else {
        try encoder.append(pcm16: pcm)
      }
      let artifact = try encoder.finish()
      var packets: [Data] = []
      try ChapterSegment.forEachPacket(in: artifact) { packets.append($0) }
      return (artifact, packets)
    }

    let (single, singlePackets) = try encode(chunkSize: nil)
    defer { try? FileManager.default.removeItem(at: single.url) }
    // 4,406 bytes: deliberately not frame- or packet-aligned.
    let (chunked, chunkedPackets) = try encode(chunkSize: 4_406)
    defer { try? FileManager.default.removeItem(at: chunked.url) }

    XCTAssertEqual(singlePackets, chunkedPackets, "chunking changed the encoded stream")
    XCTAssertEqual(single.leadingFrames, chunked.leadingFrames)
    XCTAssertEqual(single.trailingFrames, chunked.trailingFrames)
    XCTAssertGreaterThan(single.packetCount, 60)  // ~1.5 s at 1024 frames/packet
  }

  func testRejectsUnsupportedBitrateUpFront() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("enc-\(UUID().uuidString).aacseg")
    XCTAssertThrowsError(
      try AACChapterEncoder(
        artifactURL: url,
        settings: AACEncodingSettings(bitRate: 999_000),
        fingerprint: Data(count: 32))
    ) { error in
      guard case AudiobookAudioError.bitRateNotSupported = error else {
        return XCTFail("unexpected: \(error)")
      }
    }
  }

  func testRejectsMisalignedPCM() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("enc-\(UUID().uuidString).aacseg")
    let encoder = try AACChapterEncoder(
      artifactURL: url, settings: AACEncodingSettings(bitRate: 64_000),
      fingerprint: Data(count: 32))
    defer { encoder.cancel() }
    XCTAssertThrowsError(try encoder.append(pcm16: Data([1])))
  }
}

// MARK: - Job manifest / resume

final class JobManifestTests: XCTestCase {
  private func makeInputs(bitRate: Int = 256_000, voice: String = "voice.a") -> AudiobookJobInputs {
    AudiobookJobInputs(
      sourceSHA256: "abc123", voiceID: voice,
      runtimeProvenance: testRuntimeProvenance(voiceID: voice), bitRate: bitRate,
      includedSections: ["0:one", "1:two"], paragraphPauseMs: 600, chapterPauseMs: 1_750,
      announceTitles: true, maxChapters: nil, formatIdentifier: "m4b-aac-v2")
  }

  func testRuntimeModelRevisionChangesResumeIdentity() {
    let first = makeInputs()
    var second = first
    second.modelRevision = "SiriTTSService:1;macOS:26.5.2(25F84)"
    XCTAssertNotEqual(first.jobKey, second.jobKey)
    XCTAssertNotEqual(first.fingerprint, second.fingerprint)
  }

  func testPreparedResourceRevisionChangesResumeIdentity() {
    let first = makeInputs()
    var second = first
    second.runtimeProvenance = testRuntimeProvenance(
      voiceID: second.voiceID, resourceRevision: "resource-2")
    XCTAssertNotEqual(first.jobKey, second.jobKey)
    XCTAssertNotEqual(first.fingerprint, second.fingerprint)
  }

  func testGuardedReplacementRefusesChangedDestination() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let final = root.appendingPathComponent("book.m4b")
    let temporary = root.appendingPathComponent("replacement.partial")
    try Data("newer existing output".utf8).write(to: final)
    try Data("replacement".utf8).write(to: temporary)
    XCTAssertThrowsError(
      try DurableFileCommit.replace(
        final, with: temporary, expectedExistingSHA256: String(repeating: "0", count: 64)))
    XCTAssertEqual(try Data(contentsOf: final), Data("newer existing output".utf8))
    XCTAssertEqual(try Data(contentsOf: temporary), Data("replacement".utf8))

    let expected = try AudiobookJobInputs.hashSource(at: final)
    try DurableFileCommit.replaceKeepingSource(
      final, with: temporary, expectedExistingSHA256: expected)
    XCTAssertEqual(try Data(contentsOf: final), Data("replacement".utf8))
    XCTAssertEqual(
      try Data(contentsOf: temporary), Data("replacement".utf8),
      "the staged recovery copy must survive until job state is durable")
  }

  func testJobKeyIsStableAndSensitiveToEveryInput() {
    let base = makeInputs()
    XCTAssertEqual(base.jobKey, makeInputs().jobKey, "same inputs, same key")
    XCTAssertEqual(base.jobKey.count, 32)

    var changedVoice = base
    changedVoice.voiceID = "voice.b"
    XCTAssertNotEqual(base.jobKey, changedVoice.jobKey)

    var changedVoiceRevision = base
    changedVoiceRevision.voiceRevision = "2"
    XCTAssertNotEqual(base.jobKey, changedVoiceRevision.jobKey)

    var changedBackend = base
    changedBackend.backendID = "other"
    XCTAssertNotEqual(base.jobKey, changedBackend.jobKey)

    var changedImporter = base
    changedImporter.importerVersion += 1
    XCTAssertNotEqual(base.jobKey, changedImporter.jobKey)

    var changedRate = base
    changedRate.bitRate = 64_000
    XCTAssertNotEqual(base.jobKey, changedRate.jobKey)

    var changedSections = base
    changedSections.includedSections = ["0:one"]
    XCTAssertNotEqual(base.jobKey, changedSections.jobKey)

    var changedExtractor = base
    changedExtractor.extractorVersion += 1
    XCTAssertNotEqual(base.jobKey, changedExtractor.jobKey)
  }

  func testManifestRoundTripAndForce() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("jobs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let inputs = makeInputs()

    do {
      var job = try AudiobookJob.open(inputs: inputs, workRoot: root)
      try Data([1]).write(to: job.artifactURL(chapterIndex: 0))
      try job.recordCompleted(chapterIndex: 0, title: "One")
    }

    // Reopening sees the record (validation of artifact content is the
    // writer's job and is tested separately).
    do {
      let reopened = try AudiobookJob.open(inputs: inputs, workRoot: root)
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: reopened.directory.appendingPathComponent("manifest.json").path))
    }

    // force wipes everything.
    let forced = try AudiobookJob.open(inputs: inputs, workRoot: root, force: true)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: forced.artifactURL(chapterIndex: 0).path))
  }

  func testConcurrentIdenticalJobIsRejected() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("jobs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try AudiobookJob.open(inputs: makeInputs(), workRoot: root)
    XCTAssertThrowsError(try AudiobookJob.open(inputs: makeInputs(), workRoot: root)) { error in
      guard case AudiobookJobError.alreadyRunning = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    withExtendedLifetime(first) {}
  }

  func testValidatedArtifactRequiresManifestRecordAndValidFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("jobs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let inputs = makeInputs()
    let writer = M4BAudiobookWriter(
      settings: AACEncodingSettings(bitRate: inputs.bitRate), fingerprint: inputs.fingerprint)

    var job = try AudiobookJob.open(inputs: inputs, workRoot: root)
    XCTAssertNil(job.validatedArtifact(chapterIndex: 0, title: "One", writer: writer))

    // A real artifact plus its record validates.
    let segmentWriter = try ChapterSegmentWriter(
      url: job.artifactURL(chapterIndex: 0),
      settings: AACEncodingSettings(bitRate: inputs.bitRate),
      fingerprint: inputs.fingerprint)
    try segmentWriter.appendPacket(Data([9, 9]))
    _ = try segmentWriter.finalize(
      leadingFrames: 0, trailingFrames: 0, audioSpecificConfig: Data([0x11, 0x88]))
    try job.recordCompleted(chapterIndex: 0, title: "One")
    XCTAssertNotNil(job.validatedArtifact(chapterIndex: 0, title: "One", writer: writer))

    // A record whose title changed (different plan) does not validate.
    XCTAssertNil(job.validatedArtifact(chapterIndex: 0, title: "Renamed", writer: writer))
  }
}

// MARK: - Synthesizer orchestration (mock engine, recording writer)

private final class MockSentenceEngine: NarrationSynthesizing, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var maxConcurrent = 0
  private(set) var maxIndexStartedBeforeFirstUnitFinished = -1
  private var current = 0
  private var firstUnitFinished = false
  private(set) var requestedTexts: [String] = []
  var failAtText: String?
  var delayFirstSentence = false
  /// Texts the mock refuses the way the private engine refuses letterless
  /// decoration: a clean `TTSBackendError.synthesisFailed`.
  var refuseTexts: Set<String> = []

  func synthesize(text: String) async throws -> PCM16Audio {
    let unitIndex = text.hasPrefix("U")
      ? Int(text.dropFirst().prefix(while: \.isNumber)) : nil
    let shouldFail: Bool = lock.withLock {
      requestedTexts.append(text)
      current += 1
      maxConcurrent = max(maxConcurrent, current)
      if let unitIndex, unitIndex > 0, !firstUnitFinished {
        maxIndexStartedBeforeFirstUnitFinished = max(
          maxIndexStartedBeforeFirstUnitFinished, unitIndex)
      }
      return failAtText == text
    }
    defer {
      lock.withLock {
        current -= 1
        if unitIndex == 0 { firstUnitFinished = true }
      }
    }

    if refuseTexts.contains(text) { throw TTSBackendError.synthesisFailed }
    if shouldFail { throw MockFailure() }
    if delayFirstSentence, text.hasPrefix("U0 ") {
      try await Task.sleep(for: .milliseconds(80))
    }
    return try PCM16Audio(data: Self.pcm(for: text), sampleRate: 48_000, channels: 1)
  }

  /// Deterministic, text-derived PCM so ordering is byte-checkable.
  static func pcm(for text: String) -> Data {
    var hash = UInt8(truncatingIfNeeded: text.utf8.reduce(0) { $0 &+ Int($1) })
    if hash == 0 { hash = 1 }
    return Data(repeating: hash, count: 96)
  }

  struct MockFailure: Error {}
}

private struct TimingFallbackEngine: NarrationSynthesizing {
  let rejectedParagraph: String

  func synthesize(text: String) async throws -> PCM16Audio {
    try await synthesizeDetailed(text: text).audio
  }

  func synthesizeDetailed(
    text: String
  ) async throws -> (audio: PCM16Audio, timings: [SpokenWordTiming]?) {
    if text == rejectedParagraph { throw TTSBackendError.synthesisFailed }
    let words = text.split(separator: " ")
    let secondOffset = words.first.map { $0.utf16.count + 1 } ?? 0
    return (
      try PCM16Audio(
        data: MockSentenceEngine.pcm(for: text), sampleRate: 48_000, channels: 1),
      [
        SpokenWordTiming(utf16Offset: 0, utf16Length: words.first?.utf16.count ?? 1, startSeconds: 0),
        SpokenWordTiming(
          utf16Offset: secondOffset, utf16Length: words.dropFirst().first?.utf16.count ?? 1,
          startSeconds: 0.0005),
      ])
  }
}

private final class RecordingStore: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var chunksByArtifact: [URL: [Data]] = [:]
  private(set) var assembled: [(title: String, artifact: M4BChapterArtifact)] = []
  private(set) var cancelledArtifacts: [URL] = []

  func record(url: URL, chunk: Data) {
    lock.lock()
    chunksByArtifact[url, default: []].append(chunk)
    lock.unlock()
  }

  func recordCancel(url: URL) {
    lock.lock()
    cancelledArtifacts.append(url)
    lock.unlock()
  }

  func recordAssembly(_ chapters: [(title: String, artifact: M4BChapterArtifact)]) {
    lock.lock()
    assembled = chapters
    lock.unlock()
  }
}

private final class RecordingEncoder: M4BChapterEncoding {
  let url: URL
  let store: RecordingStore

  init(url: URL, store: RecordingStore) {
    self.url = url
    self.store = store
  }

  func append(pcm16: Data) throws {
    store.record(url: url, chunk: pcm16)
  }

  func finish() throws -> M4BChapterArtifact {
    try Data([1]).write(to: url)
    return M4BChapterArtifact(
      url: url, packetCount: 1, framesPerPacket: 1_024, leadingFrames: 0, trailingFrames: 0,
      payloadByteCount: 1, audioSpecificConfig: Data([0x11, 0x88]))
  }

  func cancel() {
    store.recordCancel(url: url)
  }
}

private struct RecordingWriter: M4BWriting {
  let formatIdentifier = "recording-v1"
  let fileExtension = "rec"
  let store: RecordingStore

  func makeChapterEncoder(artifactURL: URL) throws -> any M4BChapterEncoding {
    RecordingEncoder(url: artifactURL, store: store)
  }

  func validateArtifact(at url: URL) throws -> M4BChapterArtifact {
    throw AudiobookAudioError.artifactCorrupt(url, reason: "recording writer never resumes")
  }

  func assemble(
    chapters: [(title: String, artifact: M4BChapterArtifact)],
    metadata: AudiobookMetadata, cover: PublicationCover?, to outputURL: URL,
    progress: (@Sendable (Double) -> Void)?
  ) throws {
    store.recordAssembly(chapters)
    try Data([0]).write(to: outputURL)
  }
}

final class SynthesizerTests: XCTestCase {
  private func makePlan(chapters: [[String]]) -> AudiobookPlan {
    AudiobookPlan(
      sourceFormat: "test",
      importerVersion: 1,
      metadata: PublicationMetadata(
        title: "Mock Book", author: "Author", language: "en", date: "2024"),
      cover: nil,
      sections: [],
      chapters: chapters.enumerated().map { index, sentences in
        NarrationChapter(
          title: "Chapter \(index + 1)",
          announcement: nil,
          paragraphs: sentences.map { NarrationParagraph(sentences: [$0]) },
          sectionIDs: ["section-\(index)"])
      },
      warnings: [])
  }

  private func makeJob(root: URL) throws -> AudiobookJob {
    try AudiobookJob.open(
      inputs: AudiobookJobInputs(
        sourceSHA256: "x", voiceID: "v", runtimeProvenance: testRuntimeProvenance(),
        bitRate: 64_000, includedSections: [],
        paragraphPauseMs: 600, chapterPauseMs: 1_750, announceTitles: true, maxChapters: nil,
        formatIdentifier: "recording-v1"),
      workRoot: root)
  }

  func testOrderedEmissionWithSilencePlacement() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MockSentenceEngine()
    engine.delayFirstSentence = true  // forces out-of-order completion
    let store = RecordingStore()
    let sentences = ["U0 first.", "U1 second.", "U2 third."]
    let plan = makePlan(chapters: [sentences])
    let settings = SynthesisSettings(
      narratorName: "N", maxWorkers: 2,
      paragraphPauseSeconds: 0.5, chapterPauseSeconds: 1.0, headPauseSeconds: 0.25)
    let synthesizer = AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store), settings: settings)

    let output = root.appendingPathComponent("book.rec")
    var events: [AudiobookProgressEvent] = []
    for try await event in synthesizer.run(
      plan: plan, job: try makeJob(root: root), outputURL: output)
    {
      events.append(event)
    }

    let chunks = try XCTUnwrap(store.chunksByArtifact.values.first)
    let paragraphPause = SilencePCM.data(seconds: 0.5, sampleRate: 48_000)
    let expected: [Data] = [
      SilencePCM.data(seconds: 0.25, sampleRate: 48_000),
      MockSentenceEngine.pcm(for: sentences[0]), paragraphPause,
      MockSentenceEngine.pcm(for: sentences[1]), paragraphPause,
      MockSentenceEngine.pcm(for: sentences[2]),  // final paragraph: no pause
      SilencePCM.data(seconds: 1.0, sampleRate: 48_000),
    ]
    XCTAssertEqual(chunks, expected, "PCM must be emitted in source order with exact pauses")
    XCTAssertLessThanOrEqual(engine.maxConcurrent, 4, "window is 2×maxWorkers")

    XCTAssertEqual(store.assembled.map(\.title), ["Chapter 1"])
    if case .finished(let url)? = events.last { XCTAssertEqual(url, output) } else {
      XCTFail("missing finished event: \(events)")
    }
  }

  /// Paragraph mode: a multi-sentence paragraph is one synthesis unit, so
  /// the engine can pace sentence transitions itself.
  func testParagraphIsSingleSynthesisUnit() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MockSentenceEngine()
    let store = RecordingStore()
    let plan = AudiobookPlan(
      sourceFormat: "test",
      importerVersion: 1,
      metadata: PublicationMetadata(title: "Mock"),
      cover: nil,
      sections: [],
      chapters: [
        NarrationChapter(
          title: "Chapter 1",
          announcement: nil,
          paragraphs: [
            NarrationParagraph(sentences: ["First sentence.", "Second sentence."]),
            NarrationParagraph(sentences: ["Third sentence."]),
          ],
          sectionIDs: ["section-0"])
      ],
      warnings: [])
    let settings = SynthesisSettings(
      narratorName: "N", paragraphPauseSeconds: 0.5,
      chapterPauseSeconds: 0.5, headPauseSeconds: 0.25)

    for try await _ in AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store), settings: settings
    ).run(plan: plan, job: try makeJob(root: root), outputURL: root.appendingPathComponent("b.rec"))
    {}

    let chunks = try XCTUnwrap(store.chunksByArtifact.values.first)
    let expected: [Data] = [
      SilencePCM.data(seconds: 0.25, sampleRate: 48_000),
      MockSentenceEngine.pcm(for: "First sentence. Second sentence."),
      SilencePCM.data(seconds: 0.5, sampleRate: 48_000),
      MockSentenceEngine.pcm(for: "Third sentence."),
      SilencePCM.data(seconds: 0.5, sampleRate: 48_000),
    ]
    XCTAssertEqual(chunks, expected, "two paragraphs → two units with one pause between")
    XCTAssertEqual(
      engine.requestedTexts,
      ["First sentence. Second sentence.", "Third sentence."],
      "successful paragraphs must never be split speculatively")
  }

  func testSentenceGranularityUsesExactUnitsWithoutInternalPauses() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MockSentenceEngine()
    let store = RecordingStore()
    let plan = AudiobookPlan(
      sourceFormat: "test",
      importerVersion: 1,
      metadata: PublicationMetadata(title: "Mock"),
      cover: nil,
      sections: [],
      chapters: [
        NarrationChapter(
          title: "Chapter 1",
          announcement: nil,
          paragraphs: [
            NarrationParagraph(sentences: ["First sentence.", "Second sentence."]),
            NarrationParagraph(sentences: ["Third sentence."]),
          ],
          sectionIDs: ["section-0"])
      ],
      warnings: [])
    let settings = SynthesisSettings(
      narratorName: "N", paragraphPauseSeconds: 0.5,
      chapterPauseSeconds: 0.25, headPauseSeconds: 0,
      emitTimeline: true, unitGranularity: .sentence)
    let job = try makeJob(root: root)

    for try await _ in AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store), settings: settings
    ).run(plan: plan, job: job, outputURL: root.appendingPathComponent("b.rec"))
    {}

    let sourceOrder = ["First sentence.", "Second sentence.", "Third sentence."]
    XCTAssertEqual(
      engine.requestedTexts.count, sourceOrder.count,
      "every sentence must be submitted exactly once")
    XCTAssertEqual(
      Set(engine.requestedTexts), Set(sourceOrder),
      "worker request arrival order is concurrent; membership must remain lossless")
    XCTAssertEqual(
      try XCTUnwrap(store.chunksByArtifact.values.first),
      [
        Data(),
        MockSentenceEngine.pcm(for: "First sentence."),
        MockSentenceEngine.pcm(for: "Second sentence."),
        SilencePCM.data(seconds: 0.5, sampleRate: 48_000),
        MockSentenceEngine.pcm(for: "Third sentence."),
        SilencePCM.data(seconds: 0.25, sampleRate: 48_000),
      ],
      "sentence pieces concatenate directly; only the complete paragraph receives its pause")

    let timeline = try JSONDecoder().decode(
      ChapterSynthesisTimeline.self,
      from: Data(
        contentsOf: AudiobookSynthesizer.timelineURL(
          forArtifact: job.artifactURL(chapterIndex: 0))))
    XCTAssertEqual(timeline.sentences.map(\.text), sourceOrder)
    XCTAssertEqual(timeline.sentences.map(\.derivation), [.unit, .unit, .unit])
    XCTAssertEqual(timeline.units.map(\.text), sourceOrder)
    XCTAssertEqual(timeline.segments.map(\.text), sourceOrder)
  }

  func testRejectedParagraphFallsBackToSentencePiecesWithoutInternalPauses() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let paragraph = "First sentence. Second sentence."
    let engine = MockSentenceEngine()
    engine.refuseTexts = [paragraph]
    let store = RecordingStore()
    let plan = AudiobookPlan(
      sourceFormat: "test", importerVersion: 1,
      metadata: PublicationMetadata(title: "Mock"), cover: nil, sections: [],
      chapters: [
        NarrationChapter(
          title: "Chapter 1", announcement: nil,
          paragraphs: [
            NarrationParagraph(sentences: ["First sentence.", "Second sentence."]),
            NarrationParagraph(sentences: ["Afterward."]),
          ],
          sectionIDs: ["section-0"])
      ], warnings: [])
    var events: [AudiobookProgressEvent] = []
    let job = try makeJob(root: root)
    for try await event in AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store),
      settings: SynthesisSettings(
        narratorName: "N", paragraphPauseSeconds: 0.5,
        chapterPauseSeconds: 0.25, headPauseSeconds: 0,
        emitTimeline: true)
    ).run(plan: plan, job: job, outputURL: root.appendingPathComponent("b.rec"))
    {
      events.append(event)
    }

    XCTAssertEqual(engine.requestedTexts.count, 4)
    XCTAssertEqual(Set(engine.requestedTexts), Set([
      paragraph, "First sentence.", "Second sentence.", "Afterward.",
    ]))
    XCTAssertLessThan(
      try XCTUnwrap(engine.requestedTexts.firstIndex(of: "First sentence.")),
      try XCTUnwrap(engine.requestedTexts.firstIndex(of: "Second sentence.")),
      "fallback pieces must be submitted in source order")
    let chunks = try XCTUnwrap(store.chunksByArtifact.values.first)
    XCTAssertEqual(
      chunks,
      [
        Data(),
        MockSentenceEngine.pcm(for: "First sentence.")
          + MockSentenceEngine.pcm(for: "Second sentence."),
        SilencePCM.data(seconds: 0.5, sampleRate: 48_000),
        MockSentenceEngine.pcm(for: "Afterward."),
        SilencePCM.data(seconds: 0.25, sampleRate: 48_000),
      ],
      "fallback PCM must be concatenated directly; only the paragraph pause follows it")
    XCTAssertTrue(
      events.contains {
        if case .warning(let message) = $0 {
          return message.contains("chapter 1, unit 1") && message.contains("2 sentence pieces")
        }
        return false
      })
    let timeline = try JSONDecoder().decode(
      ChapterSynthesisTimeline.self,
      from: Data(
        contentsOf: AudiobookSynthesizer.timelineURL(
          forArtifact: job.artifactURL(chapterIndex: 0))))
    XCTAssertEqual(timeline.sentences.prefix(2).map(\.derivation), [.words, .words])
    XCTAssertEqual(timeline.sentences.prefix(2).map(\.startFrame), [0, 48])
    XCTAssertEqual(
      timeline.segments.prefix(2).map(\.text),
      ["First sentence.", "Second sentence."])
    XCTAssertEqual(timeline.segments.prefix(2).map(\.startFrame), [0, 48])
    XCTAssertEqual(
      timeline.sentences[2].derivation, .unit,
      "an engine with no callbacks keeps a successful utterance as one exact segment")
  }

  func testRejectedSentenceRecursivelyFallsBackWithoutInventingSentenceTiming() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let sentence = "Alpha beta gamma delta."
    let engine = MockSentenceEngine()
    engine.refuseTexts = [sentence, "Alpha beta"]
    let store = RecordingStore()
    let plan = AudiobookPlan(
      sourceFormat: "test", importerVersion: 1,
      metadata: PublicationMetadata(title: "Mock"), cover: nil, sections: [],
      chapters: [
        NarrationChapter(
          title: "Chapter 1", announcement: nil,
          paragraphs: [NarrationParagraph(sentences: [sentence])],
          sectionIDs: ["section-0"])
      ], warnings: [])
    var events: [AudiobookProgressEvent] = []
    let job = try makeJob(root: root)
    for try await event in AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store),
      settings: SynthesisSettings(
        narratorName: "N", chapterPauseSeconds: 0.25, headPauseSeconds: 0,
        emitTimeline: true, unitGranularity: .sentence)
    ).run(plan: plan, job: job, outputURL: root.appendingPathComponent("b.rec"))
    {
      events.append(event)
    }

    XCTAssertEqual(
      Set(engine.requestedTexts),
      Set([sentence, "Alpha beta", "Alpha", "beta", "gamma delta."]))
    XCTAssertEqual(
      try XCTUnwrap(store.chunksByArtifact.values.first),
      [
        Data(),
        MockSentenceEngine.pcm(for: "Alpha")
          + MockSentenceEngine.pcm(for: "beta")
          + MockSentenceEngine.pcm(for: "gamma delta."),
        SilencePCM.data(seconds: 0.25, sampleRate: 48_000),
      ],
      "failure-only subdivisions must concatenate directly with no internal silence")
    XCTAssertTrue(
      events.contains {
        if case .warning(let message) = $0 {
          return message.contains("chapter 1, unit 1")
            && message.contains("3 bounded pieces")
        }
        return false
      })

    let timeline = try JSONDecoder().decode(
      ChapterSynthesisTimeline.self,
      from: Data(
        contentsOf: AudiobookSynthesizer.timelineURL(
          forArtifact: job.artifactURL(chapterIndex: 0))))
    XCTAssertEqual(timeline.units.map(\.text), [sentence])
    XCTAssertEqual(timeline.sentences.map(\.text), [sentence])
    XCTAssertEqual(timeline.sentences.map(\.derivation), [.words])
    XCTAssertEqual(timeline.sentences[0].startFrame, 0)
    XCTAssertEqual(timeline.sentences[0].endFrame, 144)
  }

  func testExhaustedSentenceFallbackFailsClearly() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paragraph = "First sentence. Unsplit."
    let engine = MockSentenceEngine()
    engine.refuseTexts = [paragraph, "Unsplit."]
    let plan = AudiobookPlan(
      sourceFormat: "test", importerVersion: 1,
      metadata: PublicationMetadata(title: "Mock"), cover: nil, sections: [],
      chapters: [
        NarrationChapter(
          title: "Chapter 1", announcement: nil,
          paragraphs: [
            NarrationParagraph(sentences: ["First sentence.", "Unsplit."])
          ], sectionIDs: ["section-0"])
      ], warnings: [])

    do {
      for try await _ in AudiobookSynthesizer(
        sentences: engine, writer: RecordingWriter(store: RecordingStore()),
        settings: SynthesisSettings(narratorName: "N")
      ).run(plan: plan, job: try makeJob(root: root), outputURL: root.appendingPathComponent("b.rec"))
      {}
      XCTFail("a refused fallback piece must abort")
    } catch let error as AudiobookRunError {
      XCTAssertTrue(error.localizedDescription.contains("sentence fallback was exhausted"))
      XCTAssertFalse(error.localizedDescription.contains("First sentence"))
    }
  }

  func testFallbackWordTimingsAreRebasedAcrossConcatenatedPieces() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paragraph = "First alpha. Second beta."
    let plan = AudiobookPlan(
      sourceFormat: "test", importerVersion: 1,
      metadata: PublicationMetadata(title: "Mock"), cover: nil, sections: [],
      chapters: [
        NarrationChapter(
          title: "Chapter 1", announcement: nil,
          paragraphs: [
            NarrationParagraph(sentences: ["First alpha.", "Second beta."])
          ], sectionIDs: ["section-0"])
      ], warnings: [])
    let job = try makeJob(root: root)
    let output = root.appendingPathComponent("b.rec")
    for try await _ in AudiobookSynthesizer(
      sentences: TimingFallbackEngine(rejectedParagraph: paragraph),
      writer: RecordingWriter(store: RecordingStore()),
      settings: SynthesisSettings(
        narratorName: "N", headPauseSeconds: 0, emitTimeline: true)
    ).run(plan: plan, job: job, outputURL: output)
    {}

    let timelineData = try Data(
      contentsOf: AudiobookSynthesizer.timelineURL(forArtifact: job.artifactURL(chapterIndex: 0)))
    let timeline = try JSONDecoder().decode(ChapterSynthesisTimeline.self, from: timelineData)
    XCTAssertEqual(timeline.sentences.count, 2)
    XCTAssertEqual(timeline.sentences.map(\.derivation), [.words, .words])
    XCTAssertEqual(timeline.sentences[0].startFrame, 0)
    XCTAssertEqual(
      timeline.sentences[1].startFrame, 48,
      "the second piece starts after the first piece's 48 PCM frames")
    XCTAssertEqual(timeline.sentences[1].words?.first?.startFrame, 48)
  }

  /// A letterless unit the engine refuses becomes silence and the book
  /// continues; a speechless unit the engine accepts keeps its real audio.
  func testRefusedLetterlessUnitFallsBackToSilence() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MockSentenceEngine()
    engine.refuseTexts = ["—", "____________________"]
    let store = RecordingStore()
    let sentences = ["Sentinel alpha.", "—", "…", "____________________", "Sentinel omega."]
    let plan = makePlan(chapters: [sentences])
    let settings = SynthesisSettings(
      narratorName: "N", paragraphPauseSeconds: 0.5,
      chapterPauseSeconds: 1.0, headPauseSeconds: 0.25)

    for try await _ in AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store), settings: settings
    ).run(plan: plan, job: try makeJob(root: root), outputURL: root.appendingPathComponent("b.rec"))
    {}

    let chunks = try XCTUnwrap(store.chunksByArtifact.values.first)
    let pause = SilencePCM.data(seconds: 0.5, sampleRate: 48_000)
    let expected: [Data] = [
      SilencePCM.data(seconds: 0.25, sampleRate: 48_000),
      MockSentenceEngine.pcm(for: "Sentinel alpha."), pause,
      Data(), pause,  // refused "—" → silence fallback
      MockSentenceEngine.pcm(for: "…"), pause,  // accepted speechless unit keeps audio
      Data(), pause,  // refused rule line → silence fallback
      MockSentenceEngine.pcm(for: "Sentinel omega."),
      SilencePCM.data(seconds: 1.0, sampleRate: 48_000),
    ]
    XCTAssertEqual(chunks, expected)
  }

  /// A rejected word that has no safe clause/whitespace subdivision still
  /// aborts instead of being split into fragments and mispronounced.
  func testRefusedUnsplittableLetteredUnitStillAborts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MockSentenceEngine()
    engine.refuseTexts = ["Unsplit."]
    let store = RecordingStore()
    let plan = makePlan(chapters: [["Unsplit.", "Sentinel omega."]])
    let settings = SynthesisSettings(narratorName: "N")

    do {
      for try await _ in AudiobookSynthesizer(
        sentences: engine, writer: RecordingWriter(store: store), settings: settings
      ).run(
        plan: plan, job: try makeJob(root: root),
        outputURL: root.appendingPathComponent("b.rec"))
      {}
      XCTFail("a refused unsplittable word must abort")
    } catch let error as AudiobookRunError {
      XCTAssertTrue(error.underlying is TTSBackendError)
    }
  }

  func testSpeechlessPredicate() {
    for speechless in ["—", "······", "' )", "_", "____________________", "…", "§", "* * *"] {
      XCTAssertTrue(NarrationUnitPlanner.isSpeechless(speechless), speechless)
    }
    // Letters and all numeric categories (Nd "1914", Nl "Ⅻ", No "½") stay
    // speakable and are never eligible for the silence fallback.
    for speakable in ["§ 42", "1914", "Ⅻ", "½", "A", "º º º x", "λ", "五"] {
      XCTAssertFalse(NarrationUnitPlanner.isSpeechless(speakable), speakable)
    }
  }

  func testPathologicalSentencesAreBoundedWithoutLosingText() {
    let spaced = Array(repeating: "extraordinarilylongword", count: 4_000).joined(separator: " ")
    let unbroken = String(repeating: "x", count: 70_000)
    for text in [spaced, unbroken] {
      let chunks = NarrationUnitPlanner.chunks(for: NarrationParagraph(sentences: [text]))
      XCTAssertFalse(chunks.isEmpty)
      XCTAssertTrue(chunks.allSatisfy { $0.count <= NarrationUnitPlanner.maximumCharacters })
      XCTAssertEqual(chunks.joined().filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace })
    }
    XCTAssertEqual(NarrationUnitPlanner.deadlineSeconds(maximumUnitCharacters: 100), 60)
    XCTAssertEqual(NarrationUnitPlanner.deadlineSeconds(maximumUnitCharacters: 4_000), 300)
  }

  func testNarrationUnitChunkingPreservesSourceLocator() {
    let locator = SourceLocator(documentID: "body.xhtml", fragmentID: "chapter", blockIndex: 3)
    let text = String(repeating: "word ", count: 2_000)
    let paragraph = NarrationParagraph(
      sentences: [text], sourceLocator: locator, sourceText: text)
    let units = NarrationUnitPlanner.units(for: paragraph)

    XCTAssertGreaterThan(units.count, 1)
    XCTAssertTrue(units.allSatisfy { $0.sourceLocator == locator })
    XCTAssertTrue(units.allSatisfy { $0.sourceRange != nil })
    XCTAssertEqual(units.first?.sourceRange?.location, 0)
  }

  func testFailureIsMappedWithChapterAndSentence() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MockSentenceEngine()
    engine.failAtText = "Boom."
    let store = RecordingStore()
    let plan = makePlan(chapters: [["Fine one.", "Fine two."], ["Also fine.", "Boom.", "Never."]])
    let synthesizer = AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store),
      settings: SynthesisSettings(narratorName: "N"))

    do {
      for try await _ in synthesizer.run(
        plan: plan, job: try makeJob(root: root),
        outputURL: root.appendingPathComponent("book.rec"))
      {}
      XCTFail("expected failure")
    } catch let error as AudiobookRunError {
      XCTAssertEqual(error.chapterIndex, 1)
      XCTAssertEqual(error.chapterTitle, "Chapter 2")
      XCTAssertNotNil(error.errorDescription?.contains("re-run"))
      XCTAssertFalse(store.cancelledArtifacts.isEmpty, "failed chapter encoder is cancelled")
    }
  }

  /// Cancelling the consumer ends the stream with nil, not an error; success
  /// must therefore be signalled only by the .finished event, and no
  /// assembly may happen for a cancelled run.
  func testCancelledConsumerSeesNoFinishedEventAndNothingAssembles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MockSentenceEngine()
    engine.delayFirstSentence = true
    let store = RecordingStore()
    let plan = makePlan(chapters: [["U0 slow.", "U1 b.", "U2 c."], ["Other."]])
    let synthesizer = AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store),
      settings: SynthesisSettings(narratorName: "N"))
    let job = try makeJob(root: root)

    let consumer = Task { () -> Bool in
      var finished = false
      for try await event in synthesizer.run(
        plan: plan, job: job, outputURL: root.appendingPathComponent("book.rec"))
      {
        if case .finished = event { finished = true }
        if case .chapterStarted = event {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
      return finished
    }
    let finished = (try? await consumer.value) ?? false
    XCTAssertFalse(finished, "a cancelled run must not report success")

    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(store.assembled.isEmpty, "cancelled run must not assemble an audiobook")
  }

  /// One stalled early sentence must not let later completions pile up: the
  /// window bounds the reorder gap, so no unit beyond it may even start
  /// while the head is pending.
  func testReorderGapStaysWithinWindow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = MockSentenceEngine()
    engine.delayFirstSentence = true  // U0 stalls while the rest are instant
    let store = RecordingStore()
    let sentences = (0..<12).map { "U\($0) sentence." }
    let plan = makePlan(chapters: [sentences])
    let settings = SynthesisSettings(narratorName: "N", maxWorkers: 2)  // window 4

    for try await _ in AudiobookSynthesizer(
      sentences: engine, writer: RecordingWriter(store: store), settings: settings
    ).run(plan: plan, job: try makeJob(root: root), outputURL: root.appendingPathComponent("b.rec"))
    {}

    let maxStarted = engine.maxIndexStartedBeforeFirstUnitFinished
    XCTAssertLessThan(
      maxStarted, 4,
      "unit U\(maxStarted) started while U0 was stalled — the reorder gap exceeded the window")
  }

  func testResumeReusesValidatedChapters() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("synth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    // First run with the REAL writer at a low bitrate: tiny sine sentences.
    let inputs = AudiobookJobInputs(
      sourceSHA256: "x", voiceID: "v", runtimeProvenance: testRuntimeProvenance(),
      bitRate: 32_000, includedSections: [],
      paragraphPauseMs: 100, chapterPauseMs: 100, announceTitles: true, maxChapters: nil,
      formatIdentifier: "m4b-aac-v2")
    let writer = M4BAudiobookWriter(
      settings: AACEncodingSettings(bitRate: 32_000), fingerprint: inputs.fingerprint,
      overwriteExisting: true)
    let plan = makePlan(chapters: [["Alpha."], ["Beta."]])
    let settings = SynthesisSettings(
      narratorName: "N", paragraphPauseSeconds: 0.1,
      chapterPauseSeconds: 0.1, headPauseSeconds: 0.1)

    let toneEngine = ToneEngine()
    let output = root.appendingPathComponent("book.m4b")
    for try await _ in AudiobookSynthesizer(
      sentences: toneEngine, writer: writer, settings: settings
    ).run(plan: plan, job: try AudiobookJob.open(inputs: inputs, workRoot: root), outputURL: output)
    {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

    // Second run: an engine that must never be called proves full reuse.
    let tripwire = TripwireEngine()
    var reusedCount = 0
    for try await event in AudiobookSynthesizer(
      sentences: tripwire, writer: writer, settings: settings
    ).run(plan: plan, job: try AudiobookJob.open(inputs: inputs, workRoot: root), outputURL: output)
    {
      if case .chapterCompleted(_, _, reused: true) = event { reusedCount += 1 }
      if case .started(_, _, let reused, _, _) = event { XCTAssertEqual(reused, 2) }
    }
    XCTAssertEqual(reusedCount, 2)
  }
}

private struct ToneEngine: NarrationSynthesizing {
  func synthesize(text: String) async throws -> PCM16Audio {
    var data = Data(capacity: 9_600 * 2)
    for frame in 0..<9_600 {  // 0.2 s
      var value = Int16(sin(2 * .pi * 330 * Double(frame) / 48_000) * 9_000).littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return try PCM16Audio(data: data, sampleRate: 48_000, channels: 1)
  }
}

private struct TripwireEngine: NarrationSynthesizing {
  func synthesize(text: String) async throws -> PCM16Audio {
    XCTFail("synthesis must not run when every chapter is reused")
    throw MockSentenceEngine.MockFailure()
  }
}
