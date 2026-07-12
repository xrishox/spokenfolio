import Foundation
import XCTest

@testable import TTSKit

final class TTSBackendTests: XCTestCase {
  func testPCMRequiresWholeInterleavedFrames() throws {
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
  func prepare(voice: VoiceKey) async throws {}
  func synthesize(text: String, voice: VoiceKey) async throws -> PCM16Audio {
    try PCM16Audio(data: Data([0, 0]), sampleRate: 24_000, channels: 1)
  }
  func shutdown() async {}
}
