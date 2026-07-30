import XCTest

@testable import DocumentIOKit
@testable import ReadAloudKit

final class SynthesisStalignInputAdapterTests: XCTestCase {
  func testForcesBoundaryWhenExactSynthesisUnitsSplitOneStalignSentence() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("stalign-adapter-split-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    let transcripts = root.appendingPathComponent("transcripts")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: transcripts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("application/epub+zip".utf8).write(
      to: source.appendingPathComponent("mimetype"))
    try Data(
      """
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body>
      <p><span id="chapter.xhtml-s0">Alpha beta gamma delta.</span></p>
      </body></html>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/chapter.xhtml"))
    let baseline = root.appendingPathComponent("baseline.epub")
    try zip(source, to: baseline)

    let transcriptURL = transcripts.appendingPathComponent("track-0000.json")
    try JSONEncoder().encode(
      StalignTranscript(timedEntries: [
        StalignTimelineEntry(
          type: "segment", text: "Alpha beta", startTime: 0, endTime: 1,
          confidence: 1),
        StalignTimelineEntry(
          type: "segment", text: "gamma delta.", startTime: 1, endTime: 2,
          confidence: 1),
      ])
    ).write(to: transcriptURL)

    let sidecar = root.appendingPathComponent("timeline.json")
    let locator: [String: Any] = [
      "documentID": "OEBPS/chapter.xhtml", "fragmentID": NSNull(), "blockIndex": 0,
    ]
    let sidecarJSON: [String: Any] = [
      "schemaVersion": 3,
      "sourceEPUBSHA256": String(repeating: "a", count: 64),
      "m4bSHA256": String(repeating: "b", count: 64),
      "sampleRate": 48_000, "timelineCoverage": 1.0,
      "chapters": [[
        "index": 0, "title": "One", "startFrame": 0,
        "presentedFrames": 96_000, "contentOffsetFrames": 0,
        "sourceDocuments": ["OEBPS/chapter.xhtml"],
        "segments": [
          [
            "text": "Alpha beta", "kind": "prose",
            "startFrame": 0, "endFrame": 48_000,
            "sourceLocator": locator,
            "sourceRange": ["location": 0, "length": 10],
          ],
          [
            "text": "gamma delta.", "kind": "prose",
            "startFrame": 48_000, "endFrame": 96_000,
            "sourceLocator": locator,
            "sourceRange": ["location": 11, "length": 12],
          ],
        ], "sentences": [],
      ]],
    ]
    try JSONSerialization.data(withJSONObject: sidecarJSON).write(to: sidecar)

    let adapted = root.appendingPathComponent("adapted.epub")
    try SynthesisStalignInputAdapter.prepare(
      baselineMarkedup: baseline, transcriptions: transcripts,
      sidecar: sidecar, to: adapted)
    let adaptedArchive = try ZIPArchive(url: adapted, limits: .readAloud)
    let adaptedXHTML = String(
      decoding: try adaptedArchive.data(
        for: XCTUnwrap(adaptedArchive.entry(at: "OEBPS/chapter.xhtml"))),
      as: UTF8.self)
    XCTAssertTrue(adaptedXHTML.contains("\u{2029}"))
    XCTAssertTrue(adaptedXHTML.contains("Alpha beta"))
    XCTAssertTrue(adaptedXHTML.contains("gamma delta."))
    XCTAssertFalse(adaptedXHTML.contains("chapter.xhtml-s0"))

    let restored = root.appendingPathComponent("restored.epub")
    try SynthesisStalignInputAdapter.restore(aligned: adapted, to: restored)
    let restoredArchive = try ZIPArchive(url: restored, limits: .readAloud)
    let restoredXHTML = String(
      decoding: try restoredArchive.data(
        for: XCTUnwrap(restoredArchive.entry(at: "OEBPS/chapter.xhtml"))),
      as: UTF8.self)
    XCTAssertTrue(restoredXHTML.contains("Alpha beta gamma delta."))
    XCTAssertFalse(restoredXHTML.contains("\u{2029}"))
  }

  func testMergesStalignSentencesInsideOneExactSynthesisUnitAndRestoresText() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("stalign-adapter-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    let transcripts = root.appendingPathComponent("transcripts")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: transcripts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("application/epub+zip".utf8).write(
      to: source.appendingPathComponent("mimetype"))
    try Data(
      """
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body>
      <p><span id="chapter.xhtml-s0">First sentence. </span><span id="chapter.xhtml-s1"><em>Second</em> sentence!</span></p>
      </body></html>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/chapter.xhtml"))
    let baseline = root.appendingPathComponent("baseline.epub")
    try zip(source, to: baseline)

    let transcriptURL = transcripts.appendingPathComponent("track-0000.json")
    let transcript = StalignTranscript(timedEntries: [
      StalignTimelineEntry(
        type: "segment", text: "First sentence. Second sentence!",
        startTime: 0.25, endTime: 2.0, confidence: 1),
    ])
    try JSONEncoder().encode(transcript).write(to: transcriptURL)

    let sidecar = root.appendingPathComponent("timeline.json")
    let sidecarJSON: [String: Any] = [
      "schemaVersion": 3,
      "sourceEPUBSHA256": String(repeating: "a", count: 64),
      "m4bSHA256": String(repeating: "b", count: 64),
      "sampleRate": 48_000,
      "timelineCoverage": 1.0,
      "chapters": [
        [
          "index": 0, "title": "One", "startFrame": 0,
          "presentedFrames": 96_000, "contentOffsetFrames": 0,
          "sourceDocuments": ["OEBPS/chapter.xhtml"],
          "segments": [
            [
              "text": "First sentence. Second sentence!",
              "kind": "prose", "startFrame": 12_000, "endFrame": 96_000,
              "sourceLocator": [
                "documentID": "OEBPS/chapter.xhtml",
                "fragmentID": NSNull(), "blockIndex": 0,
              ],
              "sourceRange": ["location": 0, "length": 32],
            ]
          ],
          "sentences": [],
        ]
      ],
    ]
    try JSONSerialization.data(withJSONObject: sidecarJSON).write(to: sidecar)

    let adapted = root.appendingPathComponent("adapted.epub")
    try SynthesisStalignInputAdapter.prepare(
      baselineMarkedup: baseline, transcriptions: transcripts,
      sidecar: sidecar, to: adapted)
    let adaptedArchive = try ZIPArchive(url: adapted, limits: .readAloud)
    let adaptedXHTML = String(
      decoding: try adaptedArchive.data(
        for: XCTUnwrap(adaptedArchive.entry(at: "OEBPS/chapter.xhtml"))),
      as: UTF8.self)
    XCTAssertTrue(adaptedXHTML.contains("\u{E000}"))
    XCTAssertTrue(adaptedXHTML.contains("<em>Second</em>"))
    XCTAssertFalse(adaptedXHTML.contains("chapter.xhtml-s0"))
    XCTAssertFalse(adaptedXHTML.contains("chapter.xhtml-s1"))
    XCTAssertTrue(try StalignTranscriptValidator.decode(transcriptURL)
      .timeline[0].text.contains("\u{E000}"))

    let restored = root.appendingPathComponent("restored.epub")
    try SynthesisStalignInputAdapter.restore(aligned: adapted, to: restored)
    let restoredArchive = try ZIPArchive(url: restored, limits: .readAloud)
    let restoredXHTML = String(
      decoding: try restoredArchive.data(
        for: XCTUnwrap(restoredArchive.entry(at: "OEBPS/chapter.xhtml"))),
      as: UTF8.self)
    XCTAssertTrue(restoredXHTML.contains("First sentence."))
    XCTAssertTrue(restoredXHTML.contains("<em>Second</em> sentence!"))
    XCTAssertFalse(restoredXHTML.contains("\u{E000}"))
  }

  private func zip(_ source: URL, to output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = source
    process.arguments = ["-q", "-X", "-r", output.path, "."]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
