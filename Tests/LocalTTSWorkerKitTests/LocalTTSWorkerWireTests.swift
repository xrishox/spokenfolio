import Foundation
import XCTest

@testable import LocalTTSWorkerKit
@testable import TTSKit

final class LocalTTSWorkerWireTests: XCTestCase {
  func testRequestRoundTripPreservesSelectionControlsAndMode() throws {
    let selection = TTSVoiceSelection(
      voice: VoiceKey(
        backendID: TTSBackendID(rawValue: "siri-fm"),
        modelID: "siri-expressive",
        voiceID: "en-US-F"),
      controls: TTSSynthesisControls(
        pace: try TTSPreset(2), expressivity: try TTSPreset(5)))
    let request = LocalTTSWorkerRequest(
      request: TTSSynthesisRequest(
        text: "A complete paragraph.", selection: selection,
        utteranceMode: .singleUtterance, timingMode: .word))
    let pipe = Pipe()

    try LocalTTSWorkerFraming.writeRequest(request, to: pipe.fileHandleForWriting)
    try pipe.fileHandleForWriting.close()
    let decoded = try XCTUnwrap(
      LocalTTSWorkerFraming.readRequest(from: pipe.fileHandleForReading))

    XCTAssertEqual(decoded, request)
  }

  func testLegacyRequestWithoutCanonicalRequestIsRejected() {
    let legacy = Data(#"{"id":"\#(UUID().uuidString)","text":"Legacy."}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(LocalTTSWorkerRequest.self, from: legacy))
  }

  func testRequestRejectsHeaderOverflowBeforeTransport() throws {
    let pathological = "a" + String(repeating: "\u{0301}", count: 33_000)
    let request = LocalTTSWorkerRequest(
      request: TTSSynthesisRequest(
        text: pathological,
        selection: TTSVoiceSelection(
          voice: VoiceKey(
            backendID: TTSBackendID(rawValue: "siri"),
            modelID: "siri-private",
            voiceID: "test"))))

    XCTAssertThrowsError(try LocalTTSWorkerFraming.validateRequest(request)) { error in
      guard case LocalTTSWorkerProtocolError.frameTooLarge = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testResponseCarriesActualAudioFormatTimingsAndProvenance() throws {
    let pipe = Pipe()
    let audio = try PCM16Audio(
      data: Data([0, 0, 1, 0]), sampleRate: 24_000, channels: 1)
    let timings = [SpokenWordTiming(utf16Offset: 0, utf16Length: 1, startSeconds: 0)]
    let provenance = try TTSRuntimeProvenance(
      backendID: TTSBackendID(rawValue: "siri-fm"),
      modelID: "siri-expressive", voiceID: "en-US-F",
      operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
      frameworkIdentifier: "com.apple.siri.SiriTTSService", frameworkVersion: "1",
      adapterIdentifier: "com.apple.fm.language.instruct_3b.voice",
      backendAdapterRevision: "1")
    let id = UUID()

    try LocalTTSWorkerFraming.writeResponse(
      requestID: id, audio: audio, timings: timings,
      provenance: provenance, to: pipe.fileHandleForWriting)
    try pipe.fileHandleForWriting.close()
    let result = try LocalTTSWorkerFraming.readDetailedResponse(
      from: pipe.fileHandleForReading, requestID: id)

    XCTAssertEqual(result.audio, audio)
    XCTAssertEqual(result.timings, timings)
    XCTAssertEqual(result.provenance, provenance)
  }

  func testResponseRejectsInconsistentSuccessHeader() throws {
    let requestID = UUID()
    let pipe = Pipe()
    let header = LocalTTSWorkerResponseHeader(
      id: requestID, ok: true, pcmLength: 0, errorCode: "unexpected")
    let data = try JSONEncoder().encode(header)
    var length = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &length) {
      try pipe.fileHandleForWriting.write(contentsOf: Data($0))
    }
    try pipe.fileHandleForWriting.write(contentsOf: data)
    try pipe.fileHandleForWriting.close()

    XCTAssertThrowsError(
      try LocalTTSWorkerFraming.readDetailedResponse(
        from: pipe.fileHandleForReading, requestID: requestID)
    ) { error in
      guard case LocalTTSWorkerProtocolError.invalidPayloadLength = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testResponseRejectsMismatchedRequestID() throws {
    let pipe = Pipe()
    let audio = try PCM16Audio(data: Data([0, 0]), sampleRate: 48_000, channels: 1)
    try LocalTTSWorkerFraming.writeResponse(
      requestID: UUID(), audio: audio, to: pipe.fileHandleForWriting)
    try pipe.fileHandleForWriting.close()

    XCTAssertThrowsError(
      try LocalTTSWorkerFraming.readDetailedResponse(
        from: pipe.fileHandleForReading, requestID: UUID())) { error in
          guard case LocalTTSWorkerProtocolError.mismatchedResponse = error else {
            return XCTFail("unexpected error: \(error)")
          }
        }
  }
}
