import XCTest
import PublicationKit
@testable import EPUBKit

@testable import AudiobookKit

final class NarrationExtractionTests: XCTestCase {
  private func extract(body: String) throws -> ExtractedDocument {
    let document = try XHTMLDocument.parse(Data(EPUBFixture.xhtml(body: body).utf8))
    return NarrationExtractor.extract(from: document)
  }

  func testParagraphsAndHeadingsBecomeSeparateParagraphs() throws {
    let extracted = try extract(
      body: "<h1>Title Here</h1><p>First one.</p><div><p>Second one.</p></div>")
    XCTAssertEqual(extracted.paragraphs, ["Title Here", "First one.", "Second one."])
    XCTAssertEqual(extracted.firstHeading, "Title Here")
  }

  func testInlineMarkupContributesToOneParagraph() throws {
    let extracted = try extract(
      body: "<p>One <em>emphasized</em> and <span class=\"x\">styled</span> line.</p>")
    XCTAssertEqual(extracted.paragraphs, ["One emphasized and styled line."])
  }

  func testBlockSourceLocatorSurvivesFiltering() throws {
    let document = try XHTMLDocument.parse(
      Data(
        EPUBFixture.xhtml(
          body: """
            <section id="chapter-one">
              <p>Kept prose.<a epub:type="noteref" href="#fn1">1</a></p>
              <aside id="fn1" epub:type="footnote"><p>Dropped note.</p></aside>
            </section>
            """).utf8))
    let extracted = NarrationExtractor.extract(from: document, documentID: "body.xhtml")

    XCTAssertEqual(extracted.blocks.map(\.text), ["Kept prose."])
    XCTAssertEqual(
      extracted.blocks.first?.locator,
      SourceLocator(documentID: "body.xhtml", fragmentID: "chapter-one", blockIndex: 0))
  }

  func testProseLinksKeepTheirTextButNoterefsAreDropped() throws {
    let extracted = try extract(
      body: """
        <p>See the <a href="https://example.com/map">official map</a> today
        <span id="a1"/><a href="fn1.xhtml" epub:type="noteref">1</a>.</p>
        """)
    XCTAssertEqual(extracted.paragraphs, ["See the official map today ."])
    XCTAssertTrue(extracted.droppedNoteContent)
  }

  func testTier1SemanticNotesAreDropped() throws {
    let extracted = try extract(
      body: """
        <p>Kept prose.</p>
        <aside epub:type="footnote"><p>Note body.</p></aside>
        <div role="doc-endnote"><p>Endnote body.</p></div>
        <span epub:type="pagebreak" id="pg5"/>
        """)
    XCTAssertEqual(extracted.paragraphs, ["Kept prose."])
    XCTAssertTrue(extracted.droppedNoteContent)
  }

  func testTier2HeuristicsRequireConjunctions() throws {
    // sup + lone fragment anchor: dropped.
    let sup = try extract(body: "<p>Text<sup><a href=\"#fn1\">1</a></sup> continues.</p>")
    XCTAssertEqual(sup.paragraphs, ["Text continues."])

    // Marker-shaped anchor to a note-shaped target: dropped.
    let marker = try extract(
      body: "<p>Weapons<a href=\"notes.xhtml#n3\">[3]</a> everywhere.</p>")
    XCTAssertEqual(marker.paragraphs, ["Weapons everywhere."])

    // Marker-shaped anchor to a NON-note target: kept (a real cross-reference).
    let kept = try extract(body: "<p>See page<a href=\"ch2.xhtml\">2</a> for maps.</p>")
    XCTAssertEqual(kept.paragraphs, ["See page2 for maps."])

    // id+class conjunction: dropped subtree.
    let block = try extract(
      body: """
        <p>Prose.</p>
        <div id="fn2" class="footnote"><p>2. The note text. <a href="#r2">↩</a></p></div>
        """)
    XCTAssertEqual(block.paragraphs, ["Prose."])

    // note-shaped id alone (no class, no backlink): kept — one signal is not enough.
    let single = try extract(body: "<div id=\"note1\"><p>An author aside worth hearing.</p></div>")
    XCTAssertEqual(single.paragraphs, ["An author aside worth hearing."])
  }

  func testNotesOnlyFileIsDetectedForTier3() throws {
    let extracted = try extract(
      body: """
        <aside epub:type="footnote"><p><a href="c1.xhtml#a1">1</a> Translator's Note: text.</p></aside>
        """)
    XCTAssertTrue(extracted.isNotesOnly)
  }

  func testNonTextContentIsDropped() throws {
    let extracted = try extract(
      body: """
        <p><span id="page_16"/>Before the image.</p>
        <p><img src="pic.jpg" alt="decorative"/></p>
        <hr class="scene"/>
        <figure><img src="map.jpg"/><figcaption>The map.</figcaption></figure>
        <style>p { color: red }</style>
        <p>After<br/>the break.</p>
        """)
    XCTAssertEqual(extracted.paragraphs, ["Before the image.", "After the break."])
  }

  func testListsTablesAndBlockquotes() throws {
    let extracted = try extract(
      body: """
        <blockquote><p>Quoted line.</p></blockquote>
        <ul><li>First item.</li><li>Second item.</li></ul>
        <table><tr><td>Cell one.</td><td>Cell two.</td></tr></table>
        """)
    XCTAssertEqual(
      extracted.paragraphs,
      ["Quoted line.", "First item.", "Second item.", "Cell one.", "Cell two."])
  }
}

final class AnnouncementDedupeTests: XCTestCase {
  func testThreeBodyShapeSkipsAnnouncement() {
    // Body already narrates number, title, and setting.
    let decision = TitleAnnouncement.decide(
      title: "1. The Madness Years",
      bodyParagraphs: ["1", "The Madness Years", "China, 1967"])
    XCTAssertEqual(decision, .init(announce: false, absorbedParagraphCount: 0))
  }

  func testMistbornShapeAnnouncesAndAbsorbsBareNumber() {
    let decision = TitleAnnouncement.decide(
      title: "Chapter 1",
      bodyParagraphs: ["1", "Vin watched the crew from the shadows."])
    XCTAssertEqual(decision, .init(announce: true, absorbedParagraphCount: 1))
  }

  func testTitleWordsInsideProseDoNotSuppressAnnouncement() {
    let decision = TitleAnnouncement.decide(
      title: "Chapter 7: The Mists",
      bodyParagraphs: ["Something else entirely opens this chapter."])
    XCTAssertTrue(decision.announce)
  }

  func testRestOfTitleInOpeningTextSuppressesAnnouncement() {
    let decision = TitleAnnouncement.decide(
      title: "Chapter 3: Silent Spring",
      bodyParagraphs: ["SILENT SPRING", "Two years later, the mountains."])
    XCTAssertFalse(decision.announce)
  }

  func testPartSeparatorBodySuppressesAnnouncement() {
    let decision = TitleAnnouncement.decide(
      title: "Part I: Silent Spring",
      bodyParagraphs: ["PART I", "SILENT SPRING"])
    XCTAssertFalse(decision.announce)
  }

  func testShortRestDoesNotFalselySuppress() {
    // rest = "Vin" (3 normalized chars) appears in text but is below the
    // 4-char floor, so the announcement stays.
    let decision = TitleAnnouncement.decide(
      title: "Chapter 2: Vin",
      bodyParagraphs: ["Vin walked in."])
    XCTAssertTrue(decision.announce)
  }

  func testShortTitlesAreAlwaysAnnounced() {
    // Roman-numeral and bare-number titles normalize to 1-2 chars, which
    // would match inside almost any prose; they must announce (with the
    // duplicate leading heading absorbed) instead of erratically skipping.
    let roman = TitleAnnouncement.decide(
      title: "I",
      bodyParagraphs: ["It was the best of times, it was the worst of times."])
    XCTAssertTrue(roman.announce)

    let digit = TitleAnnouncement.decide(
      title: "1",
      bodyParagraphs: ["1", "In the year 1967 everything changed."])
    XCTAssertTrue(digit.announce)
    XCTAssertEqual(digit.absorbedParagraphCount, 1, "the duplicate bare heading is absorbed")
  }

  func testNormalization() {
    XCTAssertEqual(TitleAnnouncement.normalize("Café — №1!"), "cafeno1")
    XCTAssertEqual(TitleAnnouncement.normalize("THE Madness—Years"), "themadnessyears")
    XCTAssertEqual(TitleAnnouncement.normalize("  "), "")
  }
}
