import Foundation
import XCTest

@testable import TTSKit

final class TTSBackendTests: XCTestCase {
  func testSpokenWordTimingValidationRejectsUnsafePayloadsAndDeduplicates() throws {
    let text = "One two."
    let first = SpokenWordTiming(utf16Offset: 0, utf16Length: 3, startSeconds: 0)
    let second = SpokenWordTiming(utf16Offset: 4, utf16Length: 4, startSeconds: 0.25)
    XCTAssertEqual(
      try SpokenWordTimingValidator.validate(
        [first, first, second], text: text, audioDuration: 1),
      [first, second])

    XCTAssertThrowsError(
      try SpokenWordTimingValidator.validate(
        [.init(utf16Offset: 7, utf16Length: 2, startSeconds: 0)],
        text: text, audioDuration: 1))
    XCTAssertThrowsError(
      try SpokenWordTimingValidator.validate(
        [first, .init(utf16Offset: 4, utf16Length: 4, startSeconds: 1.2)],
        text: text, audioDuration: 1))
    XCTAssertThrowsError(
      try SpokenWordTimingValidator.validate(
        [second, first], text: text, audioDuration: 1))
  }

  func testPresetValidationAndNeutralDefault() throws {
    XCTAssertEqual(TTSPreset.neutral.rawValue, 3)
    XCTAssertEqual(try TTSPreset(1).rawValue, 1)
    XCTAssertEqual(try TTSPreset(5).rawValue, 5)
    XCTAssertThrowsError(try TTSPreset(0))
    XCTAssertThrowsError(try TTSPreset(6))

    XCTAssertThrowsError(try JSONDecoder().decode(TTSPreset.self, from: Data("0".utf8)))
    XCTAssertEqual(
      try JSONDecoder().decode(TTSPreset.self, from: Data("4".utf8)).rawValue,
      4)
  }

  func testCapabilitiesRejectUnsupportedControls() throws {
    let controls = TTSSynthesisControls(
      pace: try TTSPreset(2), expressivity: try TTSPreset(4))
    XCTAssertNoThrow(
      try TTSModelCapabilities(pace: true, expressivity: true).validate(controls))
    XCTAssertThrowsError(
      try TTSModelCapabilities(pace: false, expressivity: true).validate(controls))
    XCTAssertThrowsError(
      try TTSModelCapabilities(pace: true, expressivity: false).validate(controls))
  }

  func testRequestDefaultsAndCodableRoundTripPreserveFullSelection() throws {
    let key = VoiceKey(
      backendID: TTSBackendID(rawValue: "local"), modelID: "expressive", voiceID: "voice")
    let request = TTSSynthesisRequest(
      text: "One complete paragraph.",
      selection: TTSVoiceSelection(
        voice: key,
        controls: TTSSynthesisControls(
          pace: try TTSPreset(1), expressivity: try TTSPreset(5))))

    XCTAssertEqual(request.utteranceMode, .singleUtterance)
    XCTAssertEqual(request.timingMode, .none)
    XCTAssertEqual(request.selection.voice, key)
    XCTAssertEqual(request.selection.controls.pace?.rawValue, 1)
    XCTAssertEqual(request.selection.controls.expressivity?.rawValue, 5)
    XCTAssertEqual(
      try JSONDecoder().decode(
        TTSSynthesisRequest.self, from: JSONEncoder().encode(request)),
      request)
  }

  func testLegacyRequestDecodingUsesSafeDefaults() throws {
    let json = #"{"text":"Legacy.","selection":{"voice":{"backendID":"siri","modelID":"siri-private","voiceID":"voice"}}}"#
    let request = try JSONDecoder().decode(TTSSynthesisRequest.self, from: Data(json.utf8))

    XCTAssertEqual(request.utteranceMode, .singleUtterance)
    XCTAssertEqual(request.timingMode, .none)
    XCTAssertEqual(request.selection.controls, .none)
  }

  /// One prepared session serves every voice its backend offers, so a
  /// session-level provenance check must compare the ENGINE identity, not the
  /// prepared voice — otherwise every HTTP request for a non-default voice is
  /// rejected as inconsistent.
  func testEngineIdentityIgnoresVoiceButNotTheEngine() throws {
    let first = try makeProvenance(voiceID: "voice-a")
    let second = try makeProvenance(voiceID: "voice-b")
    XCTAssertNotEqual(first, second, "the two differ, as whole values")
    XCTAssertEqual(
      first.engineIdentity, second.engineIdentity,
      "two voices from one engine share an engine identity")

    let otherEngine = try TTSRuntimeProvenance(
      backendID: first.backendID, modelID: first.modelID, voiceID: "voice-a",
      operatingSystemVersion: first.operatingSystemVersion,
      operatingSystemBuild: "different-build",
      frameworkIdentifier: first.frameworkIdentifier,
      frameworkVersion: first.frameworkVersion)
    XCTAssertNotEqual(
      first.engineIdentity, otherEngine.engineIdentity,
      "a different OS build is a different engine")
  }

  func testRuntimeProvenanceRequiresExactBoundedIdentity() throws {
    XCTAssertNoThrow(try makeProvenance())
    XCTAssertThrowsError(
      try makeProvenance(resourceIdentity: String(repeating: "x", count: 1_025)))
    XCTAssertThrowsError(try makeProvenance(voiceID: ""))
  }

  func testSessionPreparationReturnsAuthoritativeProvenance() async throws {
    let backend = TestBackend(id: "local")
    let session = try backend.makeSession(
      configuration: TTSWorkloadConfiguration(
        purpose: .http, maxConcurrency: 1, maxQueuedRequests: 1, deadlineSeconds: 5))
    let request = TTSSynthesisRequest(
      text: "Compatibility.", selection: TTSVoiceSelection(voice: backend.defaultVoice),
      utteranceMode: .sentenceSequence, timingMode: .word)

    let prepared = try await session.prepare(selection: request.selection)
    let result = try await session.synthesize(request: request)

    XCTAssertEqual(prepared.voiceID, backend.defaultVoice.voiceID)
    XCTAssertEqual(result.audio.sampleRate, 24_000)
    XCTAssertNil(result.timings)
    XCTAssertNil(result.provenance)
  }

  func testQuotedAndBracketedSentenceEndingsAreComplete() {
    XCTAssertEqual(splitCompleteSentences("She asked, “Why?”").complete, ["She asked, “Why?”"])
    XCTAssertEqual(splitCompleteSentences("Done! (Really.)").complete, ["Done!", "(Really.)"])
    XCTAssertEqual(detectSentences("She said “hello”"), ["She said “hello.”"])
  }

  func testPCMRequiresWholeInterleavedFrames() throws {
    XCTAssertThrowsError(try PCM16Audio(data: Data(), sampleRate: 48_000, channels: 1))
    XCTAssertThrowsError(try PCM16Audio(data: Data([0, 1]), sampleRate: 48_000, channels: 2))
    XCTAssertNoThrow(try PCM16Audio(data: Data([0, 1, 2, 3]), sampleRate: 48_000, channels: 2))
  }

  func testRegistryRejectsDuplicateBackendIDs() {
    let first = TestBackend(id: "local")
    let second = TestBackend(id: "local")
    XCTAssertThrowsError(try TTSBackendRegistry([first, second])) { error in
      guard case TTSRegistryError.duplicateBackend(let id) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(id.rawValue, "local")
    }
  }

  func testVoiceKeysPreventCrossBackendCollisions() throws {
    let first = TestBackend(id: "one")
    let second = TestBackend(id: "two")
    let registry = try TTSBackendRegistry([second, first])

    XCTAssertEqual(registry.backendIDs.map(\.rawValue), ["one", "two"])
    XCTAssertEqual(Set(registry.voices.map(\.key)).count, 2)
    XCTAssertEqual(Set(registry.voices.map(\.key.voiceID)), ["shared-voice"])
  }

  private func makeProvenance(
    voiceID: String = "voice", resourceIdentity: String? = nil
  ) throws -> TTSRuntimeProvenance {
    try TTSRuntimeProvenance(
      backendID: TTSBackendID(rawValue: "siri"), modelID: "siri-private",
      voiceID: voiceID,
      operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
      frameworkIdentifier: "com.apple.siri.SiriTTSService", frameworkVersion: "1",
      backendAdapterRevision: "1", modelRevision: "2",
      resourceIdentity: resourceIdentity)
  }

  func testNormalizerConvertsStereo24kHzToMono48kHz() throws {
    var pcm = Data()
    for frame in 0..<2_400 {
      var left = Int16(frame % 1_000).littleEndian
      var right = Int16(-(frame % 1_000)).littleEndian
      withUnsafeBytes(of: &left) { pcm.append(contentsOf: $0) }
      withUnsafeBytes(of: &right) { pcm.append(contentsOf: $0) }
    }
    let normalized = try PCMNormalizer.normalize(
      PCM16Audio(data: pcm, sampleRate: 24_000, channels: 2))

    XCTAssertEqual(normalized.sampleRate, 48_000)
    XCTAssertEqual(normalized.channels, 1)
    XCTAssertGreaterThan(normalized.data.count, 9_000)
    XCTAssertTrue(normalized.data.count.isMultiple(of: 2))
  }
}

private struct TestBackend: TTSBackendFactory {
  let id: TTSBackendID
  let voices: [VoiceDescriptor]
  let defaultVoice: VoiceKey

  init(id: String) {
    self.id = TTSBackendID(rawValue: id)
    defaultVoice = VoiceKey(backendID: self.id, modelID: "model", voiceID: "shared-voice")
    voices = [
      VoiceDescriptor(
        key: defaultVoice, name: "Shared", language: "en-US", quality: "test")
    ]
  }

  func resolveVoice(_ requested: String) -> VoiceKey? {
    requested == defaultVoice.voiceID ? defaultVoice : nil
  }

  func makeSession(configuration: TTSWorkloadConfiguration) throws -> any TTSSession {
    TestSession()
  }
}

private struct TestSession: TTSSession {
  func prepare(selection: TTSVoiceSelection) async throws -> TTSRuntimeProvenance {
    try TTSRuntimeProvenance(
      backendID: selection.voice.backendID, modelID: selection.voice.modelID,
      voiceID: selection.voice.voiceID,
      operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
      frameworkIdentifier: "test.framework", frameworkVersion: "1")
  }
  func synthesize(request: TTSSynthesisRequest) async throws -> TTSSynthesisResult {
    TTSSynthesisResult(
      audio: try PCM16Audio(data: Data([0, 0]), sampleRate: 24_000, channels: 1))
  }
  func shutdown() async {}
}
