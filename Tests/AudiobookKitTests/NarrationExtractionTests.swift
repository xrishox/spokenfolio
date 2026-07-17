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
    XCTAssertEqual(extracted.paragraphs, ["See the official map today."])
    XCTAssertTrue(extracted.droppedNoteContent)
  }

  func testNoteOmissionRepairsOnlyLocalWrappersAndPunctuation() throws {
    let extracted = try extract(
      body: """
        <p>Alpha (<a epub:type="noteref" href="#fn1">1</a>) continues.</p>
        <p>Beta [<a role="doc-noteref" href="#fn2">2</a>, <a role="doc-noteref" href="#fn3">3</a>].</p>
        <p>Gamma<a epub:type="noteref" href="#fn4">4</a>, then delta.</p>
        """)
    XCTAssertEqual(
      extracted.paragraphs,
      ["Alpha continues.", "Beta.", "Gamma, then delta."])
  }

  func testOrdinaryVisibleProseAndLinkLabelsAreNeverPatternDeleted() throws {
    let extracted = try extract(
      body: """
        <p>Keep (this parenthetical), [this aside], and {this example}.</p>
        <p>Visit <a href="https://example.com/image.jpg">the illustrated archive</a>.</p>
        <p>The literal text https://example.com/path is part of the prose.</p>
        """)
    XCTAssertEqual(
      extracted.paragraphs,
      [
        "Keep (this parenthetical), [this aside], and {this example}.",
        "Visit the illustrated archive.",
        "The literal text https://example.com/path is part of the prose.",
      ])
  }

  private func extract(body: String, apparatusClasses: Set<String>) throws -> ExtractedDocument {
    let document = try XHTMLDocument.parse(Data(EPUBFixture.xhtml(body: body).utf8))
    return NarrationExtractor.extract(from: document, apparatusClasses: apparatusClasses)
  }

  /// Verse numbers (NRSVue shape: styled spans glued to the following word)
  /// and superscripted endnote markers (Popper shape) are numbering
  /// apparatus a narrator never speaks. Chapter headings and prose numbers
  /// must be untouched.
  func testVerseNumberSequencesAreNotNarrated() throws {
    let verses = (1...6).map {
      "<span class=\"vn\">\($0)</span>Verse text number \($0) continues here. "
    }.joined()
    let extracted = try extract(
      body: "<h2>Genesis 1</h2><p>\(verses)</p>", apparatusClasses: ["vn"])
    XCTAssertEqual(extracted.paragraphs.first, "Genesis 1", "chapter heading is spoken")
    let bodyText = extracted.paragraphs[1]
    XCTAssertFalse(bodyText.contains("1Verse"), "verse numbers are dropped")
    XCTAssertFalse(bodyText.hasPrefix("1"))
    XCTAssertTrue(bodyText.hasPrefix("Verse text number 1 continues"))
    XCTAssertTrue(bodyText.contains("here. Verse text number 2"))
  }

  func testSuperscriptEndnoteMarkerSequencesAreNotNarrated() throws {
    let prose = (1...5).map {
      "Sentence with a claim.<sup> \($0)</sup> More prose follows \(1770 + $0). "
    }.joined()
    let extracted = try extract(body: "<p>\(prose)</p>", apparatusClasses: [])
    let text = extracted.paragraphs.joined(separator: " ")
    XCTAssertFalse(text.contains("claim. 1 More"), "sup markers dropped")
    XCTAssertTrue(text.contains("claim. More prose follows 1771"),
      "plain prose numbers (years) always survive")
  }

  func testApparatusGuardsKeepMathLoneNumbersAndUnstyledText() throws {
    // Antifragile shape: styled, but not an ascending run — kept.
    let scattered = "<p>" + [7, 3, 9, 2, 5].map {
      "value <span class=\"vn\">\($0)</span> appears. "
    }.joined() + "</p>"
    XCTAssertTrue(
      try extract(body: scattered, apparatusClasses: ["vn"]).paragraphs[0].contains("value 7"),
      "non-ascending styled numbers are kept")

    // Exponents: glued to a word character — kept even in sequence.
    let mathBody = "<p>" + (1...6).map { "x<sup>\($0)</sup> plus " }.joined() + "</p>"
    XCTAssertTrue(
      try extract(body: mathBody, apparatusClasses: []).paragraphs[0].contains("x1 plus"),
      "exponent-shaped glued numbers are kept")

    // A lone inline chapter number — kept (density guard).
    XCTAssertEqual(
      try extract(
        body: "<p><span class=\"vn\">1</span>It was a dark night.</p>",
        apparatusClasses: ["vn"]
      ).paragraphs, ["1It was a dark night."])

    // Dense ascending but with no apparatus styling at all — kept.
    let unstyled = "<p>" + (1...6).map { "<span>\($0)</span> item. " }.joined() + "</p>"
    XCTAssertTrue(
      try extract(body: unstyled, apparatusClasses: []).paragraphs[0].contains("1 item"),
      "unstyled sequences are kept")
  }

  func testApparatusDropNeverFusesWordsAndUnstyledInterleavedGroupJoins() throws {
    // NRSVue shape: superscript mid-verse numbers carry their leading space
    // inside the span; paragraph-initial numbers use a different, bold (not
    // superscript) class but continue the same ascending sequence.
    // Verses 1..15 in five paragraphs: each opens with a bold ("pi") number
    // and continues with superscript-class ("vn") numbers, like the NRSVue.
    let body = (0..<5).map { paragraph in
      let first = paragraph * 3 + 1
      return "<p><span class=\"pi\">\(first)</span>When God began."
        + "<span class=\"vn\"> \(first + 1)</span>The earth was chaos."
        + "<span class=\"vn\"> \(first + 2)</span>Then God said.</p>"
    }.joined()
    let extracted = try extract(body: body, apparatusClasses: ["vn"])
    let text = extracted.paragraphs.joined(separator: " ")
    XCTAssertFalse(text.contains("2"), "styled members dropped")
    XCTAssertFalse(text.contains("1When"), "interleaved unstyled group joins the apparatus")
    XCTAssertTrue(text.contains("began. The earth"), "no fused words after dropping")
    XCTAssertTrue(text.hasPrefix("When God began."))

    // The interleave extension is unreachable without an independently fired
    // styled group: the same unstyled sequence alone stays narrated.
    let unstyledOnly = """
      <p><span class="pi">1</span>One. <span class="pi">2</span>Two. <span class="pi">3</span>Three.
      <span class="pi">4</span>Four. <span class="pi">5</span>Five. <span class="pi">6</span>Six.</p>
      """
    let kept = try extract(body: unstyledOnly, apparatusClasses: [])
    XCTAssertTrue(kept.paragraphs[0].contains("1One"), "no fired group, extension inert")
  }

  func testApparatusClassParsingFromCSS() {
    let css = """
      .verse { font-size: 0.75em; vertical-align: super; }
      .num { font-size: 0.7em; }
      .big { font-size: 1.2em; }
      .drop { font-weight: bold; margin-right: 0.25em; }
      """
    let classes = ApparatusNumberDetection.apparatusClasses(css: css)
    XCTAssertEqual(classes, ["verse", "num"], "only superscript/reduced-size classes qualify")
  }

  /// Regression (A Dance with Dragons appendix): the Siri voice verbalizes
  /// "•" (spoken as "comma" in the synthesized audio), so list markers and
  /// scene-break decoration must never reach synthesis. Prose-attached
  /// decoration and legitimate middle dots must survive untouched.
  func testListMarkersAndSceneBreakDecorationAreNotNarrated() throws {
    let extracted = try extract(
      body: """
        <p>MANCE RAYDER, King-Beyond-the-Wall, a captive at Castle Black,</p>
        <p>• his wife, {DALLA}, died in childbirth,</p>
        <p>•their newborn son, born in battle,</p>
        <p>* * *</p>
        <p>❦</p>
        <p>The next scene begins.</p>
        """)
    XCTAssertEqual(
      extracted.paragraphs,
      [
        "MANCE RAYDER, King-Beyond-the-Wall, a captive at Castle Black,",
        "his wife, {DALLA}, died in childbirth,",
        "their newborn son, born in battle,",
        "The next scene begins.",
      ])
  }

  func testProseAttachedDecorationAndMiddleDotsSurvive() throws {
    let extracted = try extract(
      body: """
        <p>The word col·laborar is Catalan and ロバート・ジョーダン is a name.</p>
        <p>He wrote *emphasis* and cited a source† in passing.</p>
        <p>Roughly ~40 pages remained.</p>
        """)
    XCTAssertEqual(
      extracted.paragraphs,
      [
        "The word col·laborar is Catalan and ロバート・ジョーダン is a name.",
        "He wrote *emphasis* and cited a source† in passing.",
        "Roughly ~40 pages remained.",
      ])
  }

  func testHiddenDecorationIsDroppedButMediaOnlyHiddenTextCanBeFallback() throws {
    let ornament = try extract(
      body: "<p>Before <span aria-hidden=\"true\">— decorative —</span> after.</p>")
    XCTAssertEqual(ornament.paragraphs, ["Before after."])

    let fixedLayout = try extract(
      body: """
        <div><img src="page.jpg" alt=""/></div>
        <div style="visibility: hidden"><p>This is a complete hidden text layer for an image-only fixed-layout page.</p></div>
        """)
    XCTAssertEqual(
      fixedLayout.paragraphs,
      ["This is a complete hidden text layer for an image-only fixed-layout page."])
    XCTAssertEqual(fixedLayout.warnings.count, 1)

    let positionedSpaces = try extract(
      body: """
        <img src="page.jpg" alt=""/>
        <div style="visibility: hidden">
          <div><span style="display:inline-block;width:100px">ALICE'S</span><span style="display:inline-block;width:20px"> </span><span style="display:inline-block;width:200px">ADVENTURES IN WONDERLAND WITH MANY CURIOUS FRIENDS</span></div>
        </div>
        """)
    XCTAssertEqual(
      positionedSpaces.paragraphs,
      ["ALICE'S ADVENTURES IN WONDERLAND WITH MANY CURIOUS FRIENDS"])

    let duplicate = try extract(
      body: """
        <p>This is the primary visible representation with enough substantial prose to narrate safely.</p>
        <div hidden="hidden"><p>This is a duplicate hidden representation with enough substantial prose to ignore safely.</p></div>
        """)
    XCTAssertEqual(
      duplicate.paragraphs,
      ["This is the primary visible representation with enough substantial prose to narrate safely."])
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

    // A superscript fragment link is not enough without marker-shaped text.
    let linkedWord = try extract(
      body: "<p>The <sup><a href=\"#definition\">technical</a></sup> term stays.</p>")
    XCTAssertEqual(linkedWord.paragraphs, ["The technical term stays."])

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

  func testShortProseIsNeverAbsorbedBySubstringCoincidence() {
    let decision = TitleAnnouncement.decide(title: "Night", bodyParagraphs: ["I", "continued."])
    XCTAssertEqual(decision, .init(announce: true, absorbedParagraphCount: 0))
  }

  func testNonLatinHeadingCanSuppressDuplicateAnnouncement() {
    let decision = TitleAnnouncement.decide(
      title: "第一章", bodyParagraphs: ["第一章", "故事开始了。"])
    XCTAssertEqual(decision, .init(announce: false, absorbedParagraphCount: 0))
    XCTAssertEqual(TitleAnnouncement.normalize("第一章"), "第一章")
  }

  func testNormalization() {
    XCTAssertEqual(TitleAnnouncement.normalize("Café — №1!"), "cafeno1")
    XCTAssertEqual(TitleAnnouncement.normalize("THE Madness—Years"), "themadnessyears")
    XCTAssertEqual(TitleAnnouncement.normalize("  "), "")
  }
}
