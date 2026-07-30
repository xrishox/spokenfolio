import XCTest

@testable import AudiobookKit
@testable import TTSKit

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

  func testDeriveSentencesRequiresAndUsesEngineAnchors() throws {
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
    let sentences = try ChapterSynthesisTimeline.deriveSentences(
      sentencesByUnit: [["Aaaa.", "Bb."], [], ["Solo."]], units: units,
      wordsByUnit: [
        [
          SpokenWordTiming(utf16Offset: 0, utf16Length: 5, startSeconds: 0),
          SpokenWordTiming(utf16Offset: 6, utf16Length: 3, startSeconds: 0.1),
        ],
        nil,
        [SpokenWordTiming(utf16Offset: 0, utf16Length: 5, startSeconds: 0)],
      ])
    XCTAssertEqual(sentences.count, 3, "speechless unit contributes nothing")
    XCTAssertEqual(sentences[0].startFrame, 1_000)
    XCTAssertEqual(sentences[0].derivation, .words)
    XCTAssertEqual(sentences[1].startFrame, 5_800)
    XCTAssertEqual(sentences[1].endFrame, 10_000, "last sentence ends at unit end")
    XCTAssertEqual(sentences[2].derivation, .words)
    XCTAssertEqual(sentences[2].startFrame, 10_200)
    XCTAssertEqual(sentences[2].endFrame, 14_200)

    let coarse = try ChapterSynthesisTimeline.deriveSentences(
      sentencesByUnit: [["Aaaa.", "Bb."]], units: [units[0]])
    XCTAssertEqual(coarse.count, 1)
    XCTAssertEqual(coarse[0].text, units[0].text)
    XCTAssertEqual(coarse[0].derivation, .unit)
    XCTAssertEqual(coarse[0].startFrame, units[0].startFrame)
    XCTAssertEqual(coarse[0].endFrame, units[0].startFrame + units[0].frameCount)
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
      sourceDocuments: ["OEBPS/c1.xhtml"], units: [], segments: [], sentences: [])
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

  func testBookSidecarUsesPresentedTrackTimebaseForFirstMiddleAndFinalChapters() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("book-timeline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("book.m4b")
    try Data([9, 8, 7]).write(to: output)

    var artifacts: [(title: String, artifact: M4BChapterArtifact)] = []
    var artifactURLs: [URL] = []
    for index in 0..<3 {
      let url = root.appendingPathComponent("chapter-\(index).aacseg")
      try Data([UInt8(index)]).write(to: url)
      artifactURLs.append(url)
      artifacts.append(
        (
          "Chapter \(index)",
          M4BChapterArtifact(
            url: url, packetCount: 10, framesPerPacket: 1_024,
            leadingFrames: 2_112, trailingFrames: 576,
            payloadByteCount: 1, audioSpecificConfig: Data([0x11, 0x90]))
        ))
    }

    _ = try SynthesisTimelineSidecar.write(
      jobKey: "job", fingerprintHex: "fingerprint",
      sourceEPUBSHA256: String(repeating: "a", count: 64),
      artifacts: artifacts, artifactURLs: artifactURLs,
      outputURL: output, sampleRate: 48_000)
    let sidecar = try JSONDecoder().decode(
      BookSynthesisTimeline.self,
      from: Data(contentsOf: BookSynthesisTimeline.sidecarURL(for: output)))

    XCTAssertEqual(sidecar.schemaVersion, 3)
    XCTAssertEqual(sidecar.chapters.map(\.startFrame), [0, 8_128, 18_368])
    XCTAssertEqual(sidecar.chapters.map(\.presentedFrames), [8_128, 10_240, 9_664])
    XCTAssertEqual(sidecar.chapters.map(\.contentOffsetFrames), [0, 2_112, 2_112])
  }
}
