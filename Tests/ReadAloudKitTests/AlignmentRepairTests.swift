import XCTest

@testable import DocumentIOKit
@testable import ReadAloudKit

/// Grafting an isolated repair overlay into the primary aligned EPUB must
/// produce a package the detection pass considers healed: SMIL and audio
/// entries present, manifest items and media-overlay attribute added, and
/// duration metadata consistent.
final class AlignmentRepairTests: XCTestCase {
  private func makeAligned(
    secondOverlaid: Bool, root: URL
  ) throws -> URL {
    let name = secondOverlaid ? "repair" : "primary"
    let source = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("MediaOverlays"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Audio"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
    try Data(
      """
      <?xml version="1.0"?>
      <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """.utf8
    ).write(to: source.appendingPathComponent("META-INF/container.xml"))
    let chapterOverlay = secondOverlaid
      ? ""
      : " media-overlay=\"chapter.xhtml_overlay\""
    let secondOverlay = secondOverlaid
      ? " media-overlay=\"second.xhtml_overlay\""
      : ""
    try Data(
      """
      <?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">fixture</dc:identifier><dc:title>F</dc:title><dc:language>en</dc:language>
          \(secondOverlaid
            ? """
              <meta property="media:duration" refines="#second.xhtml_overlay">00:00:04.00</meta>
              <meta property="media:duration">00:00:04.00</meta>
              """
            : """
              <meta property="media:duration" refines="#chapter.xhtml_overlay">00:00:02.00</meta>
              <meta property="media:duration">00:00:02.00</meta>
              """)
        </metadata>
        <manifest>
          <item id="chapter.xhtml" href="chapter.xhtml" media-type="application/xhtml+xml"\(chapterOverlay)/>
          <item id="second.xhtml" href="second.xhtml" media-type="application/xhtml+xml"\(secondOverlay)/>
          \(secondOverlaid
            ? """
              <item id="second.xhtml_overlay" href="MediaOverlays/second.smil" media-type="application/smil+xml"/>
              <item id="audio_00001-00002" href="Audio/00001-00002.mp4" media-type="audio/mp4"/>
              """
            : """
              <item id="chapter.xhtml_overlay" href="MediaOverlays/chapter.smil" media-type="application/smil+xml"/>
              <item id="audio_00001-00001" href="Audio/00001-00001.mp4" media-type="audio/mp4"/>
              """)
        </manifest>
        <spine><itemref idref="chapter.xhtml"/><itemref idref="second.xhtml"/></spine>
      </package>
      """.utf8
    ).write(to: source.appendingPathComponent("content.opf"))
    for doc in ["chapter", "second"] {
      try Data(
        """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(doc)</title></head>
        <body><p id="\(doc)-s0">Prose for \(doc).</p></body></html>
        """.utf8
      ).write(to: source.appendingPathComponent("\(doc).xhtml"))
    }
    let overlaid = secondOverlaid ? "second" : "chapter"
    let track = secondOverlaid ? "00001-00002" : "00001-00001"
    try Data(
      """
      <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body>
      <seq id="\(overlaid).xhtml_overlay"><par id="\(overlaid).xhtml-s0">
      <text src="../\(overlaid).xhtml#\(overlaid)-s0"/>
      <audio src="../Audio/\(track).mp4" clipBegin="0.000s" clipEnd="2.000s"/>
      </par></seq></body></smil>
      """.utf8
    ).write(to: source.appendingPathComponent("MediaOverlays/\(overlaid).smil"))
    try Data([7, 7, 7, 7]).write(to: source.appendingPathComponent("Audio/\(track).mp4"))
    let output = root.appendingPathComponent("\(name).epub")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = source
    process.arguments = ["-q", "-X", "-r", output.path, "."]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return output
  }

  func testGraftHealsMissingOverlay() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let primary = try makeAligned(secondOverlaid: false, root: root)
    let repair = try makeAligned(secondOverlaid: true, root: root)

    let narrated: Set<String> = ["chapter.xhtml", "second.xhtml"]
    XCTAssertEqual(
      try AlignmentRepair.documentsMissingOverlays(
        staged: primary, narratedDocuments: narrated),
      ["second.xhtml"])

    try AlignmentRepair.graft(document: "second.xhtml", from: repair, into: primary)

    XCTAssertEqual(
      try AlignmentRepair.documentsMissingOverlays(
        staged: primary, narratedDocuments: narrated),
      [])
    let merged = try ZIPArchive(url: primary, limits: .readAloud)
    XCTAssertNotNil(merged.entry(at: "MediaOverlays/second.smil"))
    XCTAssertNotNil(merged.entry(at: "Audio/00001-00002.mp4"))
    let opf = String(
      decoding: try merged.data(for: merged.entry(at: "content.opf")!), as: UTF8.self)
    XCTAssertTrue(opf.contains("media-overlay=\"second.xhtml_overlay\""))
    XCTAssertTrue(opf.contains("refines=\"#second.xhtml_overlay\""))
    // Total duration re-summed: 2 s existing + 4 s grafted.
    XCTAssertTrue(opf.contains(">00:00:06.00</meta>"), opf)
  }

  func testTrackStemsSelectsNarratingChapters() {
    let stems = ["00001-00001", "00001-00002", "00001-00003"]
    let chapters = [["a.xhtml"], ["b.xhtml"], ["b.xhtml", "c.xhtml"]]
    XCTAssertEqual(
      AlignmentRepair.trackStems(
        narrating: "b.xhtml", chapterSourceDocuments: chapters, stems: stems),
      ["00001-00002", "00001-00003"])
    XCTAssertEqual(
      AlignmentRepair.trackStems(
        narrating: "b.xhtml", chapterSourceDocuments: [["a.xhtml"]], stems: stems),
      [], "count mismatch returns empty rather than guessing")
  }
}
