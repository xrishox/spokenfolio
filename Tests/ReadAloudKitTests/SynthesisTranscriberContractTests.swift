import XCTest

@testable import AudiobookKit
@testable import ReadAloudKit

/// Pins the sidecar JSON contract between AudiobookKit (writer) and
/// ReadAloudKit (mirrored reader): whatever AudiobookKit encodes, the
/// transcriber's mirror must decode with identical values.
final class SynthesisTranscriberContractTests: XCTestCase {
  func testSidecarContractRoundTrip() throws {
    let sentence = ChapterSynthesisTimeline.SentenceTiming(
      text: "Hello there.", startFrame: 12_000, endFrame: 60_000,
      derivation: .interpolated, kind: .prose)
    let chapter = BookSynthesisTimeline.Chapter(
      index: 0, title: "One", artifactSHA256: "ab", startFrame: 0,
      presentedFrames: 480_000, leadingFrames: 2_112,
      sourceDocuments: ["OEBPS/c1.xhtml"], sentences: [sentence])
    let book = BookSynthesisTimeline(
      jobKey: "k", fingerprint: "f", m4bSHA256: "digest", sampleRate: 48_000,
      timelineCoverage: 1.0, chapters: [chapter])
    let data = try JSONEncoder().encode(book)

    let mirror = try JSONDecoder().decode(
      SynthesisTimelineTranscriber.Sidecar.self, from: data)
    XCTAssertEqual(mirror.schemaVersion, BookSynthesisTimeline.schemaVersion)
    XCTAssertEqual(mirror.m4bSHA256, "digest")
    XCTAssertEqual(mirror.timelineCoverage, 1.0)
    XCTAssertEqual(mirror.chapters.count, 1)
    XCTAssertEqual(mirror.chapters[0].leadingFrames, 2_112)
    XCTAssertEqual(mirror.chapters[0].presentedFrames, 480_000)
    XCTAssertEqual(mirror.chapters[0].sentences[0].text, "Hello there.")
    XCTAssertEqual(mirror.chapters[0].sentences[0].startFrame, 12_000)
    XCTAssertEqual(mirror.chapters[0].sentences[0].kind, "prose")
    XCTAssertEqual(mirror.chapters[0].sourceDocuments, ["OEBPS/c1.xhtml"])
  }

  func testFabricatedTranscriptSatisfiesValidator() throws {
    let entries = [
      StalignTimelineEntry(
        type: "segment", text: "First sentence here.",
        startTime: 0.25, endTime: 2.5, confidence: 1.0),
      StalignTimelineEntry(
        type: "segment", text: "Second one.",
        startTime: 2.5, endTime: 4.0, confidence: 1.0),
    ]
    let transcript = StalignTranscript(timedEntries: entries)
    XCTAssertNoThrow(
      try StalignTranscriptValidator.validate(
        transcript, audioDuration: 4.5, enforceDurationCeiling: true))
    XCTAssertEqual(transcript.transcript, "First sentence here. Second one.")
  }
}
