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

  /// A fixture EPUB whose spine is [c0 (cover, no overlay), chapter
  /// (narrated, has overlay)]. The cover body is caller-supplied so a test can
  /// stand in a well-formed source cover or a stalign-mangled one.
  private func makeEPUBWithCover(cover: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let src = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(
      at: src.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: src.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
    try Data("application/epub+zip".utf8).write(to: src.appendingPathComponent("mimetype"))
    try Data(
      """
      <?xml version="1.0"?>
      <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """.utf8
    ).write(to: src.appendingPathComponent("META-INF/container.xml"))
    try Data(
      """
      <?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">fixture</dc:identifier><dc:title>Fixture</dc:title><dc:language>en</dc:language>
        </metadata>
        <manifest>
          <item id="c0.xhtml" href="c0.xhtml" media-type="application/xhtml+xml" properties="svg"/>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml" media-overlay="smil"/>
          <item id="smil" href="chapter.smil" media-type="application/smil+xml"/>
          <item id="audio" href="audio.mp4" media-type="audio/ogg; codecs=opus"/>
        </manifest>
        <spine><itemref idref="c0.xhtml"/><itemref idref="chapter"/></spine>
      </package>
      """.utf8
    ).write(to: src.appendingPathComponent("OEBPS/content.opf"))
    try Data(cover.utf8).write(to: src.appendingPathComponent("OEBPS/c0.xhtml"))
    try Data(
      """
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
      <body><p id="s1">Narrated prose.</p></body></html>
      """.utf8
    ).write(to: src.appendingPathComponent("OEBPS/chapter.xhtml"))
    try Data(
      "<smil xmlns=\"http://www.w3.org/ns/SMIL\" version=\"3.0\"><body><seq>"
        .appending(
          "<par><text src=\"chapter.xhtml#s1\"/><audio src=\"audio.mp4\" clipBegin=\"0s\" clipEnd=\"1s\"/></par>")
        .appending("</seq></body></smil>").utf8
    ).write(to: src.appendingPathComponent("OEBPS/chapter.smil"))
    try Data([0, 1, 2, 3]).write(to: src.appendingPathComponent("OEBPS/audio.mp4"))
    let output = root.appendingPathComponent("fixture.epub")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = src
    zip.arguments = ["-q", "-X", "-r", output.path, "."]
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
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

  /// The real Storyteller-breaking bug: stalign's HTML reserialization
  /// unwraps the Calibre inline-SVG cover into a bare `<image xlink:href>`
  /// with an unbound prefix. The universal restore must put the pristine
  /// source cover back byte-for-byte on every path, leaving narrated
  /// documents (which carry a Media Overlay) untouched.
  func testRestoreNonNarratedPutsBackTheInlineSvgCoverFromSource() throws {
    // Source: a well-formed inline-SVG cover (spine[0]) + a narrated chapter.
    let source = try makeEPUBWithCover(
      cover:
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>c0</title></head>"
        + "<body><svg xmlns=\"http://www.w3.org/2000/svg\" "
        + "xmlns:xlink=\"http://www.w3.org/1999/xlink\"><image xlink:href=\"cover.jpg\"/>"
        + "</svg></body></html>")
    // "Aligned" stand-in: the same EPUB but with the cover mangled exactly the
    // way stalign mangles it (SVG unwrapped, xlink now unbound), and the
    // chapter carrying its Media Overlay.
    let staged = try makeEPUBWithCover(
      cover:
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>c0</title></head>"
        + "<body><image xlink:href=\"cover.jpg\"/></body></html>")

    try AlignmentSearchNeutralizer.restoreNonNarratedDocuments(source: source, staged: staged)

    let restored = try ZIPArchive(url: staged)
    let original = try ZIPArchive(url: source)
    XCTAssertEqual(
      try restored.data(for: restored.entry(at: "OEBPS/c0.xhtml")!),
      try original.data(for: original.entry(at: "OEBPS/c0.xhtml")!),
      "the cover must be byte-identical to the pristine source")
    // And it is now well-formed under strict parsing.
    XCTAssertNoThrow(
      try BoundedXMLDocument.parse(
        restored.data(for: restored.entry(at: "OEBPS/c0.xhtml")!), allowTidy: false))
    // The narrated chapter (has a Media Overlay) is NOT restored — keeps its
    // aligned markup.
    XCTAssertEqual(
      try restored.data(for: restored.entry(at: "OEBPS/chapter.xhtml")!),
      try ZIPArchive(url: staged).data(for: restored.entry(at: "OEBPS/chapter.xhtml")!))
  }

  /// The defense-in-depth gate: `verifyPublished` must REJECT a package that
  /// contains the exact failing cover (bare `<image xlink:href>`, unbound
  /// prefix) rather than let tidy repair hide it. This runs before any audio
  /// work, so a dummy ffprobe is never invoked.
  func testVerifierRejectsNotWellFormedDocument() async throws {
    let mangled = try makeEPUBWithCover(
      cover:
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>c0</title></head>"
        + "<body><image xlink:href=\"cover.jpg\"/></body></html>")
    let epubcheck = try makeEPUBCheckStub(in: mangled.deletingLastPathComponent())
    do {
      _ = try await ReadAloudVerifier.verifyPublished(
        epub: mangled, ffmpeg: URL(fileURLWithPath: "/usr/bin/true"),
        ffprobe: URL(fileURLWithPath: "/usr/bin/true"),
        epubcheck: epubcheck)
      XCTFail("a not-well-formed content document must fail verification")
    } catch let error as ReadAloudError {
      guard case .invalidArtifact(let message) = error else {
        return XCTFail("unexpected error \(error)")
      }
      XCTAssertTrue(message.contains("well-formed"), message)
      XCTAssertTrue(message.contains("c0.xhtml"), message)
    }
  }

  /// Runs the real fix over the real shipped artifact: the broken Three Days
  /// ReadAloud (whose cover Storyteller could not render) and its pristine
  /// source EPUB. Proves the production restore makes the cover byte-identical
  /// to source and that EVERY XML document then parses strictly. Gated on the
  /// two paths so normal runs skip it.
  func testFixRepairsTheRealShippedArtifact() throws {
    let env = ProcessInfo.processInfo.environment
    guard let sourcePath = env["READALOUD_REPAIR_SOURCE"],
      let brokenPath = env["READALOUD_REPAIR_BROKEN"]
    else { throw XCTSkip("set READALOUD_REPAIR_SOURCE and READALOUD_REPAIR_BROKEN") }
    let source = URL(fileURLWithPath: sourcePath)
    let staged = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).epub")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: brokenPath), to: staged)
    addTeardownBlock { try? FileManager.default.removeItem(at: staged) }

    try AlignmentSearchNeutralizer.restoreNonNarratedDocuments(source: source, staged: staged)

    let fixed = try ZIPArchive(url: staged, limits: .readAloud)
    let src = try ZIPArchive(url: source, limits: .publication)
    XCTAssertEqual(
      try fixed.data(for: fixed.entry(at: "OEBPS/c0.xhtml")!),
      try src.data(for: src.entry(at: "OEBPS/c0.xhtml")!),
      "the shipped cover must now equal the pristine source cover")
    var malformed: [String] = []
    for entry in fixed.entries {
      let l = entry.path.lowercased()
      guard l.hasSuffix(".xhtml") || l.hasSuffix(".opf") || l.hasSuffix(".ncx")
        || l.hasSuffix(".smil") || l.hasSuffix(".xml") || l.hasSuffix(".html")
      else { continue }
      if (try? BoundedXMLDocument.parse(fixed.data(for: entry), allowTidy: false)) == nil {
        malformed.append(entry.path)
      }
    }
    XCTAssertEqual(malformed, [], "every XML document must be well-formed after the fix")
  }

  /// Full EPUB 3 specification conformance via the official W3C epubcheck —
  /// the suite our own verifier is not: it validates OPF/nav/overlay rules,
  /// not just alignment semantics and well-formedness. Gated on the jar and
  /// an artifact path so normal runs skip it:
  ///   EPUBCHECK_JAR=/path/epubcheck.jar READALOUD_EPUBCHECK_EPUB=/path/x.epub
  func testEpubcheckConformanceWhenConfigured() throws {
    let env = ProcessInfo.processInfo.environment
    guard let jar = env["EPUBCHECK_JAR"], let epub = env["READALOUD_EPUBCHECK_EPUB"] else {
      throw XCTSkip("set EPUBCHECK_JAR and READALOUD_EPUBCHECK_EPUB")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/java")
    process.arguments = ["-jar", jar, epub]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    XCTAssertEqual(
      process.terminationStatus, 0,
      "epubcheck reported conformance failures:\n\(output.suffix(2000))")
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

  func testRestoreExaminesTextReferencesRatherThanSMILSubstrings() throws {
    let epub = try makeEPUB(
      smil:
        "<smil xmlns=\"http://www.w3.org/ns/SMIL\" version=\"3.0\"><body><seq>"
        + "<par><text src=\"chapter.xhtml#s1\"/><audio src=\"toc.xhtml-audio.mp4\" "
        + "clipBegin=\"0s\" clipEnd=\"1s\"/></par>"
        + "</seq></body></smil>")
    let staged = epub.deletingLastPathComponent().appendingPathComponent("staged.epub")
    try FileManager.default.copyItem(at: epub, to: staged)

    XCTAssertNoThrow(
      try AlignmentSearchNeutralizer.restore(
        targets: ["OEBPS/toc.xhtml"], markedup: epub, staged: staged))
  }
}
