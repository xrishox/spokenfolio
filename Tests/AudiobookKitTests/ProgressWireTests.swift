import TTSKit
import XCTest

@testable import AudiobookKit

/// The ndjson progress protocol is the GUI↔CLI contract: every event must
/// survive the wire byte-exactly, and malformed lines must be detectable.
final class ProgressWireTests: XCTestCase {
  private let provenance = try! TTSRuntimeProvenance(
    backendID: TTSBackendID(rawValue: "siri"), modelID: "siri-private",
    voiceID: "voice",
    operatingSystemVersion: "27.0", operatingSystemBuild: "26A1",
    frameworkIdentifier: "test.framework", frameworkVersion: "1")

  private var allEvents: [AudiobookProgressEvent] { [
    .started(
      totalChapters: 3, totalCharacters: 1_200, reusedChapters: 1,
      chapterCharacters: [400, 500, 300], runtimeProvenance: provenance),
    .chapterStarted(index: 2, title: "The Madness Years"),
    .unitCompleted(chapterIndex: 2, completed: 5, total: 12),
    .chapterCompleted(index: 2, title: "Ünïcode — em-dash \"quotes\"", reused: true),
    .assemblyStarted,
    .finished(outputURL: URL(fileURLWithPath: "/tmp/Book – Author.m4b")),
    .warning("players see only the first 255 chapters"),
  ] }

  func testRoundTripAllCases() throws {
    for event in allEvents {
      let data = try JSONEncoder().encode(ProgressEventWire(event))
      let decoded = try JSONDecoder().decode(ProgressEventWire.self, from: data)
      XCTAssertEqual(decoded.event(), event, "round trip changed \(event)")
    }
  }

  func testWireIsSingleLine() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for event in allEvents {
      let text = String(decoding: try encoder.encode(ProgressEventWire(event)), as: UTF8.self)
      XCTAssertFalse(text.contains("\n"), "embedded newline would corrupt the ndjson stream")
    }
  }

  func testMissingRequiredFieldsAreProtocolViolations() throws {
    for kind in ["started", "chapterStarted", "unitCompleted", "chapterCompleted", "finished",
      "warning"]
    {
      let bare = Data("{\"type\":\"\(kind)\"}".utf8)
      let wire = try JSONDecoder().decode(ProgressEventWire.self, from: bare)
      XCTAssertNil(wire.event(), "bare \(kind) must not decode into an event")
    }
    let assembly = Data("{\"type\":\"assemblyStarted\"}".utf8)
    XCTAssertNotNil(try JSONDecoder().decode(ProgressEventWire.self, from: assembly).event())
  }

  func testUnknownTypeFailsDecoding() {
    let unknown = Data("{\"type\":\"somethingNew\"}".utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(ProgressEventWire.self, from: unknown))
  }
}
