import XCTest
import TTSKit

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

  func testWorkloadPurposeControlsWorkerSentenceSplitting() {
    XCTAssertTrue(SiriTTSSession.workerSplitsSentences(for: .http))
    XCTAssertFalse(SiriTTSSession.workerSplitsSentences(for: .audiobook))
  }

  func testWorkerRequestRejectsHeaderOverflowBeforeTransport() {
    let pathological = "a" + String(repeating: "\u{0301}", count: 33_000)
    XCTAssertThrowsError(
      try WorkerFraming.validateRequest(text: pathological, splitSentences: true)
    ) { error in
      guard case WorkerProtocolError.frameTooLarge = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testWorkerResponseRejectsInconsistentSuccessHeader() throws {
    let requestID = UUID()
    let pipe = Pipe()
    let header = WorkerResponseHeader(
      id: requestID, ok: true, pcmLength: 0, errorCode: "unexpected")
    let data = try JSONEncoder().encode(header)
    var length = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &length) {
      try pipe.fileHandleForWriting.write(contentsOf: Data($0))
    }
    try pipe.fileHandleForWriting.write(contentsOf: data)
    XCTAssertThrowsError(
      try WorkerFraming.readResponse(
        from: pipe.fileHandleForReading, requestID: requestID)
    ) { error in
      guard case WorkerProtocolError.invalidPayloadLength = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
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

  func testVoiceDiscoveryParsesUAFLayoutAndRejectsWrongSampleRate() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("siri-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeVoiceFixture(
      root: root, directory: "valid.asset", id: "com.example.nora.natural",
      sampleRate: 48_000)
    try writeVoiceFixture(
      root: root, directory: "invalid.asset", id: "com.example.bad.natural",
      sampleRate: 24_000)

    let voices = SiriVoiceCatalog.discover(searchDirectories: [root])
    XCTAssertEqual(voices.map(\.id), ["com.example.nora.natural"])
    XCTAssertEqual(voices[0].resourcePath.hasSuffix("valid.asset/AssetData"), true)
    XCTAssertEqual(voices[0].language, "en-US")
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

  private func writeVoiceFixture(
    root: URL, directory: String, id: String, sampleRate: Int
  ) throws {
    let outer = root.appendingPathComponent(directory)
    let data = outer.appendingPathComponent("AssetData")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let outerInfo: [String: Any] = [
      "MobileAssetProperties": ["AssetSpecifier": id]
    ]
    let innerInfo: [String: Any] = [
      "MobileAssetProperties": [
        "Type": "natural",
        "Name": "nora",
        "Footprint": "premium",
        "LanguagesCompatibility": ["en_US"],
        "_ContentVersion": 7,
        "Styles": ["narration"],
      ]
    ]
    try PropertyListSerialization.data(fromPropertyList: outerInfo, format: .xml, options: 0)
      .write(to: outer.appendingPathComponent("Info.plist"))
    try PropertyListSerialization.data(fromPropertyList: innerInfo, format: .xml, options: 0)
      .write(to: data.appendingPathComponent("Info.plist"))
    try JSONSerialization.data(withJSONObject: ["graph": ["sample_rate_out": sampleRate]])
      .write(to: data.appendingPathComponent("gryphon.cfg"))
  }
}
