import XCTest

@testable import DocumentIOKit
@testable import ReadAloudKit

/// Never-narrated spine documents are emptied only in the copy stalign
/// searches and restored byte-for-byte afterward; a Media Overlay that
/// references a neutralized document proves the neutralization was wrong
/// and must abort restoration.
final class AlignmentSearchNeutralizerTests: XCTestCase {
  private func makeEPUB(
    smil: String =
      "<smil xmlns=\"http://www.w3.org/ns/SMIL\" version=\"3.0\"><body><seq>"
      + "<par><text src=\"chapter.xhtml#s1\"/><audio src=\"audio.mp4\" clipBegin=\"0s\" clipEnd=\"1s\"/></par>"
      + "</seq></body></smil>"
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: source.appendingPathComponent("mimetype"))
    try Data(
      """
      <?xml version="1.0"?>
      <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """.utf8
    ).write(to: source.appendingPathComponent("META-INF/container.xml"))
    try Data(
      """
      <?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">fixture</dc:identifier><dc:title>Fixture</dc:title><dc:language>en</dc:language>
        </metadata>
        <manifest>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml" media-overlay="smil"/>
          <item id="toc" href="toc.xhtml" media-type="application/xhtml+xml"/>
          <item id="smil" href="chapter.smil" media-type="application/smil+xml"/>
          <item id="audio" href="audio.mp4" media-type="audio/ogg; codecs=opus"/>
        </manifest>
        <spine><itemref idref="chapter"/><itemref idref="toc"/></spine>
      </package>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/content.opf"))
    try Data(
      """
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
      <body><p id="s1">Real narrated prose stays untouched.</p></body></html>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/chapter.xhtml"))
    try Data(
      """
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Contents</title></head>
      <body><p id="t1">Chapter One</p><p id="t2">Chapter Two</p></body></html>
      """.utf8
    ).write(to: source.appendingPathComponent("OEBPS/toc.xhtml"))
    try Data(smil.utf8).write(to: source.appendingPathComponent("OEBPS/chapter.smil"))
    try Data([0, 1, 2, 3]).write(to: source.appendingPathComponent("OEBPS/audio.mp4"))
    let output = root.appendingPathComponent("fixture.epub")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = source
    process.arguments = ["-q", "-X", "-r", output.path, "."]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return output
  }

  func testTargetsAreSpineDocumentsOutsideTheNarratedSet() throws {
    let epub = try makeEPUB()
    let targets = try AlignmentSearchNeutralizer.neutralizationTargets(
      markedup: epub, narratedDocuments: ["OEBPS/chapter.xhtml"])
    XCTAssertEqual(targets, ["OEBPS/toc.xhtml"])
    XCTAssertEqual(
      try AlignmentSearchNeutralizer.neutralizationTargets(
        markedup: epub,
        narratedDocuments: ["OEBPS/chapter.xhtml", "OEBPS/toc.xhtml"]),
      [])
  }

  func testNeutralizeEmptiesOnlyTargetBodiesAndRestoreIsByteExact() throws {
    let epub = try makeEPUB()
    let neutralized = epub.deletingLastPathComponent()
      .appendingPathComponent("neutralized.epub")
    try AlignmentSearchNeutralizer.writeNeutralized(
      markedup: epub, targets: ["OEBPS/toc.xhtml"], to: neutralized)

    let original = try ZIPArchive(url: epub)
    let copy = try ZIPArchive(url: neutralized)
    let emptied = try copy.data(for: copy.entry(at: "OEBPS/toc.xhtml")!)
    let emptiedText = String(decoding: emptied, as: UTF8.self)
    XCTAssertFalse(emptiedText.contains("Chapter One"))
    XCTAssertTrue(emptiedText.contains("body"), "body element survives, empty")
    XCTAssertEqual(
      try copy.data(for: copy.entry(at: "OEBPS/chapter.xhtml")!),
      try original.data(for: original.entry(at: "OEBPS/chapter.xhtml")!))

    // Restoring the aligned output (here: the neutralized copy standing in
    // for stalign's output) brings the original bytes back exactly.
    try AlignmentSearchNeutralizer.restore(
      targets: ["OEBPS/toc.xhtml"], markedup: epub, staged: neutralized)
    let restored = try ZIPArchive(url: neutralized)
    XCTAssertEqual(
      try restored.data(for: restored.entry(at: "OEBPS/toc.xhtml")!),
      try original.data(for: original.entry(at: "OEBPS/toc.xhtml")!))
  }

  func testRestoreRefusesWhenOverlayReferencesNeutralizedDocument() throws {
    let epub = try makeEPUB(
      smil:
        "<smil xmlns=\"http://www.w3.org/ns/SMIL\" version=\"3.0\"><body><seq>"
        + "<par><text src=\"toc.xhtml#t1\"/><audio src=\"audio.mp4\" clipBegin=\"0s\" clipEnd=\"1s\"/></par>"
        + "</seq></body></smil>")
    let staged = epub.deletingLastPathComponent().appendingPathComponent("staged.epub")
    try FileManager.default.copyItem(at: epub, to: staged)
    XCTAssertThrowsError(
      try AlignmentSearchNeutralizer.restore(
        targets: ["OEBPS/toc.xhtml"], markedup: epub, staged: staged))
  }
}
