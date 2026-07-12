import XCTest
@testable import EPUBKit

@testable import AudiobookKit

final class EPUBHrefTests: XCTestCase {
  func testResolvesRelativeToDeclaringDocument() {
    XCTAssertEqual(
      EPUBHref.resolve("ch1.xhtml", relativeTo: "OEBPS/nav.xhtml")?.path, "OEBPS/ch1.xhtml")
    XCTAssertEqual(
      EPUBHref.resolve("text/ch1.xhtml", relativeTo: "OEBPS/toc.ncx")?.path,
      "OEBPS/text/ch1.xhtml")
    XCTAssertEqual(
      EPUBHref.resolve("../images/a.png", relativeTo: "OEBPS/text/ch1.xhtml")?.path,
      "OEBPS/images/a.png")
    XCTAssertEqual(
      EPUBHref.resolve("./ch2.xhtml", relativeTo: "OEBPS/ch1.xhtml")?.path, "OEBPS/ch2.xhtml")
  }

  func testSplitsAndDecodesFragments() {
    let resolved = EPUBHref.resolve("ch1.xhtml#sec%201", relativeTo: "OEBPS/nav.xhtml")
    XCTAssertEqual(resolved?.path, "OEBPS/ch1.xhtml")
    XCTAssertEqual(resolved?.fragment, "sec 1")

    let selfReference = EPUBHref.resolve("#top", relativeTo: "OEBPS/ch1.xhtml")
    XCTAssertEqual(selfReference?.path, "OEBPS/ch1.xhtml")
    XCTAssertEqual(selfReference?.fragment, "top")
  }

  func testDecodesPercentEncodedPaths() {
    XCTAssertEqual(
      EPUBHref.resolve("My%20Chapter.xhtml", relativeTo: "OEBPS/nav.xhtml")?.path,
      "OEBPS/My Chapter.xhtml")
  }

  func testRejectsExternalAndEscapingPaths() {
    XCTAssertNil(EPUBHref.resolve("https://example.com/a", relativeTo: "OEBPS/nav.xhtml"))
    XCTAssertNil(EPUBHref.resolve("mailto:someone@example.com", relativeTo: "OEBPS/nav.xhtml"))
    XCTAssertNil(EPUBHref.resolve("../../outside.xhtml", relativeTo: "OEBPS/nav.xhtml"))
    XCTAssertNil(EPUBHref.resolve("", relativeTo: "OEBPS/nav.xhtml"))
  }
}

final class WhitespaceTests: XCTestCase {
  func testCollapsingWhitespace() {
    XCTAssertEqual("  a\n\t b\u{00A0}c  ".collapsingWhitespace(), "a b c")
    XCTAssertEqual("hy\u{00AD}phen".collapsingWhitespace(), "hyphen")
    XCTAssertEqual("".collapsingWhitespace(), "")
    XCTAssertEqual(" \n ".collapsingWhitespace(), "")
  }
}

final class EPUBParsingTests: XCTestCase {
  private var fixtureURLs: [URL] = []

  override func tearDown() {
    for url in fixtureURLs { try? FileManager.default.removeItem(at: url) }
    fixtureURLs = []
    super.tearDown()
  }

  private func load(_ fixture: EPUBFixture) throws -> EPUBBook {
    let url = try fixture.write()
    fixtureURLs.append(url)
    return try EPUBBook.load(url: url)
  }

  func testThreeBodyShapeParsesCompletely() throws {
    let book = try load(.threeBodyShape())

    XCTAssertEqual(book.version, "3.0")
    XCTAssertEqual(book.metadata.title, "Three Body Fixture")
    XCTAssertEqual(book.metadata.author, "Fixture Author")
    XCTAssertEqual(book.spine.count, 9)
    XCTAssertTrue(book.spine.allSatisfy(\.linear), "footnote files are linear in the spine")
    XCTAssertEqual(book.tocSource, .navDocument)

    let flattened = book.toc.flatMap(\.flattened)
    XCTAssertEqual(
      flattened.map(\.title),
      [
        "Title Page", "Copyright", "Contents", "Part I: Silent Spring",
        "1. The Madness Years", "2. Silent Spring", "About the Author",
      ])
    let part = book.toc.first(where: { $0.title.hasPrefix("Part I") })
    XCTAssertEqual(part?.children.count, 2)
    XCTAssertEqual(part?.children.first?.depth, 1)

    XCTAssertEqual(
      book.landmarks.first(where: { $0.epubType == "bodymatter" })?.path, "OEBPS/part1.xhtml")
    XCTAssertEqual(book.cover?.kind, .png)
    XCTAssertTrue(book.warnings.isEmpty, "unexpected warnings: \(book.warnings)")
  }

  func testMistbornShapeTitlesComeFromTOC() throws {
    let book = try load(.mistbornShape())

    let flattened = book.toc.flatMap(\.flattened)
    XCTAssertEqual(
      flattened.map(\.title),
      [
        "Title Page", "Dedication", "Prologue", "Part One: The Survivor of Hathsin",
        "Chapter 1", "Chapter 2",
      ])
    XCTAssertEqual(
      flattened.first(where: { $0.title == "Chapter 1" })?.fragment, "c1",
      "nav fragments map to heading ids inside chapter files")
    XCTAssertEqual(
      book.landmarks.first(where: { $0.epubType == "bodymatter" })?.path,
      "OEBPS/prologue.xhtml")
  }

  func testEPUB2FallsBackToNCXAndGuide() throws {
    let book = try load(.epub2Shape())

    XCTAssertEqual(book.version, "2.0")
    XCTAssertEqual(book.tocSource, .ncx)
    let flattened = book.toc.flatMap(\.flattened)
    XCTAssertEqual(
      flattened.map(\.title),
      ["Cover", "Chapter One", "A Section", "Chapter Two", "Notes"])
    XCTAssertEqual(
      flattened.first(where: { $0.title == "A Section" })?.fragment, "s1")

    // Guide types normalize to EPUB 3 landmark vocabulary.
    XCTAssertEqual(
      book.landmarks.first(where: { $0.epubType == "bodymatter" })?.path,
      "OEBPS/text/ch1.xhtml")
    XCTAssertEqual(
      book.landmarks.first(where: { $0.epubType == "footnotes" })?.path,
      "OEBPS/text/notes.xhtml")

    // EPUB 2 cover via <meta name="cover">.
    XCTAssertEqual(book.cover?.kind, .png)
  }

  func testSpineOnlyBookWarnsAndKeepsSpineOrder() throws {
    let book = try load(.spineOnlyShape())

    XCTAssertEqual(book.tocSource, TOCSource.none)
    XCTAssertTrue(book.toc.isEmpty)
    XCTAssertEqual(book.spine.map(\.path), ["OEBPS/one.xhtml", "OEBPS/two.xhtml"])
    XCTAssertTrue(book.warnings.contains(where: { $0.contains("table of contents") }))
  }

  func testNonLinearSpineItemsKeepTheirFlag() throws {
    var fixture = EPUBFixture.spineOnlyShape()
    fixture.documents.append(
      EPUBFixture.Document(
        id: "aux", path: "OEBPS/aux.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<p>Auxiliary content.</p>"),
        linear: false))
    let book = try load(fixture)
    XCTAssertEqual(book.spine.last?.linear, false)
    XCTAssertEqual(book.spine.last?.index, 2)
  }

  func testWrongMimetypeIsAWarningNotAFailure() throws {
    var fixture = EPUBFixture.spineOnlyShape()
    fixture.mimetype = "application/zip"
    let book = try load(fixture)
    XCTAssertTrue(book.warnings.contains(where: { $0.contains("mimetype") }))
  }

  func testMalformedXHTMLRecoversThroughTidy() throws {
    var fixture = EPUBFixture.spineOnlyShape()
    // Unclosed <p> and a bare ampersand: invalid XML, valid-enough HTML.
    fixture.documents[0] = EPUBFixture.Document(
      id: "one", path: "OEBPS/one.xhtml",
      xhtml: """
        <html><head><title>t</title></head>
        <body><h1>First Part</h1><p>Broken & unclosed<p>Second paragraph</body></html>
        """)
    let book = try load(fixture)
    let data = try book.documentData(at: "OEBPS/one.xhtml")
    let document = try XHTMLDocument.parse(data)
    XCTAssertFalse(
      try XHTMLDocument.elements(named: "p", in: document).isEmpty,
      "tidy fallback should produce a usable DOM")
  }

  func testMissingContainerFailsClearly() throws {
    var zip = ZIPFixtureWriter()
    zip.addEntry(path: "mimetype", data: Data("application/epub+zip".utf8), compress: false)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("epub-fixture-\(UUID().uuidString).epub")
    try zip.finish().write(to: url)
    fixtureURLs.append(url)

    XCTAssertThrowsError(try EPUBBook.load(url: url)) { error in
      guard case EPUBError.missingContainerXML = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  /// Gated on the real purchased books; run with e.g.
  /// AUDIOBOOK_TEST_EPUB="…/The Three-Body Problem.epub" swift test --filter RealBook
  func testRealBookParsesWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["AUDIOBOOK_TEST_EPUB"] else {
      throw XCTSkip("AUDIOBOOK_TEST_EPUB not set")
    }
    let book = try EPUBBook.load(url: URL(fileURLWithPath: path))
    XCTAssertFalse(book.spine.isEmpty)
    XCTAssertFalse(book.metadata.title.isEmpty)
  }
}
