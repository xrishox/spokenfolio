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

  func testRequestModeControlsWorkerSentenceSplitting() {
    XCTAssertTrue(SiriTTSSession.workerSplitsSentences(for: .sentenceSequence))
    XCTAssertFalse(SiriTTSSession.workerSplitsSentences(for: .singleUtterance))
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
