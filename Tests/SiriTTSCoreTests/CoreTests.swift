import XCTest

@testable import SiriTTSCore

final class CoreTests: XCTestCase {
  func testMobileAudioBitrates() {
    XCTAssertEqual(AudioResponseEncoder.opusBitRate, 64_000)
    XCTAssertEqual(AudioResponseEncoder.aacBitRate, 64_000)
  }

  func testSentenceSplittingPreservesTextAndTrailingFragment() {
    XCTAssertEqual(
      splitSentences("First sentence. Second sentence! Is this third? Final fragment"),
      ["First sentence.", "Second sentence!", "Is this third?", "Final fragment"])
    XCTAssertEqual(splitSentences(""), [])
  }

  func testWorkerFramingRoundTrip() throws {
    let requestPipe = Pipe()
    let request = WorkerRequest(id: UUID(), text: "A framed request.", splitSentences: false)
    try WorkerFraming.writeRequest(request, to: requestPipe.fileHandleForWriting)
    let decoded = try XCTUnwrap(
      WorkerFraming.readRequest(from: requestPipe.fileHandleForReading))
    XCTAssertEqual(decoded.id, request.id)
    XCTAssertEqual(decoded.text, request.text)
    XCTAssertFalse(decoded.splitSentences)

    // Frames without the field (older writers) default to sentence splitting.
    let legacy = try JSONDecoder().decode(
      WorkerRequest.self,
      from: Data(#"{"id":"\#(UUID().uuidString)","text":"Legacy."}"#.utf8))
    XCTAssertTrue(legacy.splitSentences)

    let responsePipe = Pipe()
    let pcm = Data([1, 2, 3, 4])
    try WorkerFraming.writeResponse(
      requestID: request.id, pcm: pcm, to: responsePipe.fileHandleForWriting)
    XCTAssertEqual(
      try WorkerFraming.readResponse(
        from: responsePipe.fileHandleForReading, requestID: request.id),
      pcm)
  }

  func testPermissionPreflightAcceptsReadableModel() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("siri-preflight-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("version")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([1]).write(to: nested.appendingPathComponent("model.bin"))

    XCTAssertNoThrow(try SiriPermissionPreflight.verifyModelAccess(at: root))
  }

  func testPermissionPreflightAllowsMissingOptionalSharedDirectory() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-siri-preflight-\(UUID().uuidString)")
    XCTAssertNoThrow(try SiriPermissionPreflight.verifyModelAccess(at: missing))
  }

  func testVoiceAliasesNeverSelectAnAmbiguousVariant() {
    let natural = voiceAsset(
      id: "com.apple.siri.tts.voice.en_US.nora.natural.premium",
      displayName: "Nora (Natural)",
      technology: "natural")
    let neural = voiceAsset(
      id: "com.apple.siri.tts.voice.en_US.nora.neural.premium",
      displayName: "Nora (Neural)",
      technology: "neural")
    let lookup = SiriVoiceCatalog.makeVoiceLookup([natural, neural])

    XCTAssertNil(lookup["nora"])
    XCTAssertNil(lookup["en-us:nora"])
    XCTAssertEqual(lookup["nora (natural)"], natural.id)
    XCTAssertEqual(lookup[natural.id.lowercased()], natural.id)
  }

  private func voiceAsset(
    id: String, displayName: String, technology: String
  ) -> SiriVoiceAsset {
    SiriVoiceAsset(
      id: id,
      name: "nora",
      displayName: displayName,
      language: "en-US",
      technology: technology,
      footprint: "premium",
      version: 1,
      voicePath: "/tmp/voice",
      resourcePath: "/tmp/voice",
      styles: [],
      sourcePriority: 0)
  }
}
