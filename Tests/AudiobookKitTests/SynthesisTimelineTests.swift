import XCTest

@testable import AudiobookKit

final class SynthesisTimelineTests: XCTestCase {
  func testAssignSentencesPacksWholeSentencesAndAttributesFragments() {
    // Whole sentences packed into one piece.
    XCTAssertEqual(
      AudiobookSynthesizer.assignSentences(
        ["One here.", "Two there."], toPieces: ["One here. Two there."]),
      [["One here.", "Two there."]])
    // Sentences split across two packed pieces.
    XCTAssertEqual(
      AudiobookSynthesizer.assignSentences(
        ["One here.", "Two there.", "Three now."],
        toPieces: ["One here. Two there.", "Three now."]),
      [["One here.", "Two there."], ["Three now."]])
    // A limiter fragment attributes the over-long sentence where it starts.
    let long = String(repeating: "x", count: 90)
    XCTAssertEqual(
      AudiobookSynthesizer.assignSentences(
        [long, "Tail."],
        toPieces: [String(long.prefix(50)), String(long.suffix(40)) + " Tail."]),
      [[long], ["Tail."]])
  }

  func testDeriveSentencesInterpolatesByCharacterShare() {
    let units = [
      ChapterSynthesisTimeline.UnitTiming(
        unitIndex: 0, text: "Aaaa. Bb.", kind: .prose,
        startFrame: 1_000, frameCount: 9_000, pauseAfterFrames: 100),
      ChapterSynthesisTimeline.UnitTiming(
        unitIndex: 1, text: "—", kind: .speechlessSilence,
        startFrame: 10_100, frameCount: 0, pauseAfterFrames: 100),
      ChapterSynthesisTimeline.UnitTiming(
        unitIndex: 2, text: "Solo.", kind: .prose,
        startFrame: 10_200, frameCount: 4_000, pauseAfterFrames: 0),
    ]
    let sentences = ChapterSynthesisTimeline.deriveSentences(
      sentencesByUnit: [["Aaaa.", "Bb."], [], ["Solo."]], units: units)
    XCTAssertEqual(sentences.count, 3, "speechless unit contributes nothing")
    XCTAssertEqual(sentences[0].startFrame, 1_000)
    XCTAssertEqual(sentences[0].derivation, .interpolated)
    XCTAssertEqual(sentences[1].endFrame, 10_000, "last sentence ends at unit end")
    XCTAssertGreaterThan(sentences[1].startFrame, sentences[0].endFrame - 1)
    XCTAssertEqual(sentences[2].derivation, .unit)
    XCTAssertEqual(sentences[2].startFrame, 10_200)
    XCTAssertEqual(sentences[2].endFrame, 14_200)
  }

  func testChapterTimelineRoundTripsAndBindsArtifact() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("timeline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let artifact = dir.appendingPathComponent("chapter-0000.aacseg")
    try Data([1, 2, 3, 4]).write(to: artifact)

    let timeline = ChapterSynthesisTimeline(
      jobKey: "k", chapterIndex: 0, title: "T", sampleRate: 48_000,
      headPauseFrames: 12_000,
      artifactSHA256: try ChapterSynthesisTimeline.sha256(of: artifact),
      sourceDocuments: ["OEBPS/c1.xhtml"], units: [], sentences: [])
    let data = try JSONEncoder().encode(timeline)
    let decoded = try JSONDecoder().decode(ChapterSynthesisTimeline.self, from: data)
    XCTAssertEqual(decoded, timeline)
    // Sidecars written before the source-document field decode as empty.
    var stripped = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    stripped.removeValue(forKey: "sourceDocuments")
    let legacy = try JSONDecoder().decode(
      ChapterSynthesisTimeline.self,
      from: JSONSerialization.data(withJSONObject: stripped))
    XCTAssertEqual(legacy.sourceDocuments, [])
    XCTAssertEqual(
      decoded.artifactSHA256, try ChapterSynthesisTimeline.sha256(of: artifact))
  }
}
