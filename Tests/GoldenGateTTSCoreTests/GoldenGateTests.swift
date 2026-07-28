import AudioToolbox
import Foundation
import XCTest

@testable import GoldenGateTTSCore
@testable import TTSKit

final class GoldenGateTests: XCTestCase {
  func testFloat32PCMConversionClampsAndRejectsNonfiniteSamples() throws {
    var values: [Float] = [-2, -1, -0.5, 0, 0.5, 1, 2]
    let data = values.withUnsafeBytes { Data($0) }
    let pcm = try GoldenGateAudioDecoder.convertFloat32PCM(
      data, sampleRate: 24_000, channels: 1)
    let samples: [Int16] = pcm.data.withUnsafeBytes { raw in
      Array(raw.bindMemory(to: Int16.self))
    }

    XCTAssertEqual(pcm.sampleRate, 24_000)
    XCTAssertEqual(pcm.channels, 1)
    XCTAssertEqual(samples.first, Int16.min)
    XCTAssertEqual(samples.last, Int16.max)
    XCTAssertEqual(samples[3], 0)

    values = [.nan]
    XCTAssertThrowsError(
      try GoldenGateAudioDecoder.convertFloat32PCM(
        values.withUnsafeBytes { Data($0) }, sampleRate: 24_000, channels: 1))
  }

  func testInstrumentationRequiresExactVoiceControlsAndFMAdapter() throws {
    let evidence = GoldenGateInstrumentation(
      voiceID: "en-US-F", resourceIdentity: "en-US", resourceRevision: "1023",
      errorCode: 0, pacePreset: 2, expressivityPreset: 5,
      adapterID: "com.apple.fm.language.instruct_3b.voice", audioDuration: 1.5)

    XCTAssertNoThrow(try evidence.validate(voiceID: "en-US-F", pace: 2, expressivity: 5))
    XCTAssertThrowsError(try evidence.validate(voiceID: "en-US-G", pace: 2, expressivity: 5))
    XCTAssertThrowsError(try evidence.validate(voiceID: "en-US-F", pace: 3, expressivity: 5))
  }

  func testWorkerRetainsVoiceHandleWithoutReenumeratingPerUtterance() throws {
    let runtime = RecordingGoldenGateRuntime()
    let engine = try GoldenGateWorkerEngine(voiceID: "en-US-F", runtime: runtime)
    let request = TTSSynthesisRequest(
      text: "One utterance.",
      selection: TTSVoiceSelection(
        voice: VoiceKey(
          backendID: GoldenGateTTSBackend.backendID,
          modelID: GoldenGateTTSBackend.modelID,
          voiceID: "en-US-F"),
        controls: TTSSynthesisControls(pace: .neutral, expressivity: .neutral)))

    _ = try engine.synthesize(request)
    _ = try engine.synthesize(request)

    XCTAssertEqual(runtime.enumerationCount, 1)
    XCTAssertEqual(runtime.synthesisCount, 2)
  }

  func testBackendAdvertisesExpressivePresetCapabilities() throws {
    let voice = GoldenGateVoice(
      id: "en-US-F", name: "American Voice 7", language: "en-US",
      quality: "premium", gender: 1, revision: "0")
    let backend = try GoldenGateTTSBackend(voices: [voice], makeClient: { _ in
      XCTFail("test should not create a worker")
      throw TTSBackendError.unavailable
    })

    XCTAssertEqual(backend.models.first?.key.modelID, "siri-expressive")
    XCTAssertEqual(backend.models.first?.controls.pace, .preset1Through5)
    XCTAssertEqual(backend.models.first?.controls.expressivity, .preset1Through5)
    XCTAssertEqual(backend.models.first?.recommendedAudiobookWorkers, 1)
    XCTAssertEqual(backend.models.first?.maximumAudiobookWorkers, 1)
    XCTAssertEqual(backend.defaultVoice.voiceID, "en-US-F")
  }
}

private final class RecordingGoldenGateRuntime: GoldenGateSynthesisRuntime {
  private(set) var enumerationCount = 0
  private(set) var synthesisCount = 0
  private let handle = GoldenGateVoiceHandle(
    descriptor: GoldenGateVoice(
      id: "en-US-F", name: "American Voice 7", language: "en-US",
      quality: "premium", gender: 1, revision: "1"),
    object: NSObject())

  func voices() throws -> [GoldenGateVoiceHandle] {
    enumerationCount += 1
    return [handle]
  }

  func synthesize(
    text: String, voice: GoldenGateVoiceHandle, pace: Int, expressivity: Int
  ) throws -> (audio: PCM16Audio, instrumentation: GoldenGateInstrumentation) {
    synthesisCount += 1
    return (
      try PCM16Audio(data: Data([0, 0]), sampleRate: 24_000, channels: 1),
      GoldenGateInstrumentation(
        voiceID: voice.descriptor.id,
        resourceIdentity: "en-US", resourceRevision: "1",
        errorCode: 0, pacePreset: pace, expressivityPreset: expressivity,
        adapterID: GoldenGateInstrumentation.expectedAdapterIdentifier,
        audioDuration: 0.1))
  }
}
