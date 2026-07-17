import XCTest
import EPUBKit
import PublicationKit

@testable import AudiobookKit

final class ChapterPlanningTests: XCTestCase {
  private var fixtureURLs: [URL] = []

  override func tearDown() {
    for url in fixtureURLs { try? FileManager.default.removeItem(at: url) }
    fixtureURLs = []
    super.tearDown()
  }

  private func plan(
    _ fixture: EPUBFixture, options: PlanOptions = PlanOptions()
  ) throws -> AudiobookPlan {
    let url = try fixture.write()
    fixtureURLs.append(url)
    return try AudiobookPlanner.plan(
      publication: try EPUBImporter().load(url: url), options: options)
  }

  func testThreeBodyShapePlansBodyChaptersAndSkipsApparatus() throws {
    let plan = try plan(.threeBodyShape())

    let roleBySpineIndex = Dictionary(
      uniqueKeysWithValues: plan.sections.map { ($0.index, $0.role) })
    XCTAssertEqual(roleBySpineIndex[0], .cover, "landmark cover beats title-page keyword")
    XCTAssertEqual(roleBySpineIndex[1], .copyright)
    XCTAssertEqual(roleBySpineIndex[2], .printedTOC)
    XCTAssertEqual(roleBySpineIndex[3], .part)
    XCTAssertEqual(roleBySpineIndex[4], .chapter)
    XCTAssertEqual(roleBySpineIndex[6], .notes, "linear footnote file classified via tier-3")
    XCTAssertEqual(roleBySpineIndex[7], .notes)
    XCTAssertEqual(roleBySpineIndex[8], .aboutAuthor)

    XCTAssertEqual(
      plan.chapters.map(\.title),
      ["Part I: Silent Spring", "1. The Madness Years", "2. Silent Spring"])

    // Chapter 1's dedupe: body opens with number/title/setting → no announcement.
    let chapter1 = plan.chapters[1]
    XCTAssertNil(chapter1.announcement)
    XCTAssertEqual(chapter1.paragraphs.first?.sentences, ["1"])

    // Footnote text must be gone entirely.
    let allText = plan.chapters
      .flatMap(\.allParagraphs).flatMap(\.sentences).joined(separator: " ")
    XCTAssertFalse(allText.contains("Translator"))
    XCTAssertFalse(allText.contains("cultural reference"))

    // Part separator body suppresses its own announcement (PART I SILENT SPRING).
    XCTAssertNil(plan.chapters[0].announcement)
  }

  func testMistbornShapeAnnouncesTOCOnlyTitles() throws {
    let plan = try plan(.mistbornShape())

    XCTAssertEqual(
      plan.chapters.map(\.title),
      ["Dedication", "Prologue", "Part One: The Survivor of Hathsin", "Chapter 1", "Chapter 2"])

    let chapter1 = try XCTUnwrap(plan.chapters.first(where: { $0.title == "Chapter 1" }))
    XCTAssertEqual(chapter1.announcement?.sentences, ["Chapter 1."])
    XCTAssertEqual(
      chapter1.paragraphs.first?.sentences, ["Vin watched the crew from the shadows."],
      "the bare '1' heading paragraph is absorbed by the announcement")

    let prologue = try XCTUnwrap(plan.chapters.first(where: { $0.title == "Prologue" }))
    XCTAssertNil(prologue.announcement, "body already opens with 'Prologue'")
  }

  func testSectionOverridesFlipDefaults() throws {
    var options = PlanOptions()
    options.includeSections = ["copyright"]
    options.excludeSections = ["2-silent-spring"]
    let plan = try plan(.threeBodyShape(), options: options)

    XCTAssertTrue(plan.chapters.contains(where: { $0.title == "Copyright" }))
    XCTAssertFalse(plan.chapters.contains(where: { $0.title == "2. Silent Spring" }))

    let copyright = try XCTUnwrap(plan.sections.first(where: { $0.role == .copyright }))
    XCTAssertTrue(copyright.included)
    XCTAssertFalse(copyright.includedByDefault)
  }

  func testUnknownOverrideTokenFailsLoudly() throws {
    var options = PlanOptions()
    options.excludeSections = ["no-such-slug"]
    let url = try EPUBFixture.mistbornShape().write()
    fixtureURLs.append(url)
    let publication = try EPUBImporter().load(url: url)
    XCTAssertThrowsError(try AudiobookPlanner.plan(publication: publication, options: options)) { error in
      guard case AudiobookPlanError.unknownSection("no-such-slug") = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testSpineOnlyBookGetsSyntheticUnannouncedChapters() throws {
    let plan = try plan(.spineOnlyShape())

    XCTAssertEqual(plan.chapters.map(\.title), ["First Part", "Section 2"])
    XCTAssertTrue(plan.chapters.allSatisfy { $0.announcement == nil })
  }

  func testTOCFragmentsSplitChaptersInsideOneDocument() throws {
    var fixture = EPUBFixture()
    fixture.title = "Fragment Chapters"
    fixture.documents = [
      EPUBFixture.Document(
        id: "body", path: "OEBPS/body.xhtml",
        xhtml: EPUBFixture.xhtml(
          body: """
            <section id="one"><h1>Chapter One</h1><p>First chapter prose.</p></section>
            <section id="two"><h1>Chapter Two</h1><p>Second chapter prose.</p></section>
            """))
    ]
    fixture.navXHTML = EPUBFixture.nav(
      tocItems: """
        <li><a href="body.xhtml#one">Chapter One</a></li>
        <li><a href="body.xhtml#two">Chapter Two</a></li>
        """)

    let result = try plan(fixture)
    XCTAssertEqual(result.chapters.map(\.title), ["Chapter One", "Chapter Two"])
    XCTAssertTrue(
      result.chapters[0].allParagraphs.flatMap(\.sentences).joined(separator: " ")
        .contains("First chapter prose"))
    XCTAssertFalse(
      result.chapters[0].allParagraphs.flatMap(\.sentences).joined(separator: " ")
        .contains("Second chapter prose"))
  }

  func testEPUB2NotesFileExcludedViaGuideAndHeuristics() throws {
    let plan = try plan(.epub2Shape())

    let notes = try XCTUnwrap(plan.sections.first(where: { $0.role == .notes }))
    XCTAssertFalse(notes.included)
    XCTAssertEqual(
      plan.chapters.map(\.title), ["Chapter One", "Chapter Two"],
      "cover (guide) and notes (guide/tier-3) are excluded by default")

    // The EPUB 2 sup-anchor footnote marker is gone from chapter text.
    let chapterOne = plan.chapters[0]
    let text = chapterOne.allParagraphs.flatMap(\.sentences).joined(separator: " ")
    XCTAssertFalse(text.contains("1"), "marker digit must not be narrated: \(text)")
  }

  /// An excluded chapter drops its whole spine range (excerpt spillover), but
  /// the section listing must reflect that honestly, and an explicit include
  /// override inside the range must rescue that section as its own chapter.
  func testExcludedAnchorRangeIsHonestAndExplicitIncludeRescues() throws {
    var fixture = EPUBFixture()
    fixture.title = "Range Fixture"
    fixture.documents = [
      EPUBFixture.Document(
        id: "ch1", path: "OEBPS/ch1.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Chapter One</h1><p>Real prose.</p>")),
      EPUBFixture.Document(
        id: "excerpt", path: "OEBPS/excerpt.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<p>Excerpt opening.</p>")),
      EPUBFixture.Document(
        id: "qa", path: "OEBPS/qa.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Author Interview</h1><p>Q and A text.</p>")),
    ]
    fixture.navXHTML = EPUBFixture.nav(
      tocItems: """
        <li><a href="ch1.xhtml">Chapter One</a></li>
        <li><a href="excerpt.xhtml">Excerpt from Book Two</a></li>
        """,
      landmarks: """
        <li><a epub:type="bodymatter" href="ch1.xhtml">Begin Reading</a></li>
        """)

    let defaultPlan = try plan(fixture)
    XCTAssertEqual(defaultPlan.chapters.map(\.title), ["Chapter One"])
    let interviewSection = try XCTUnwrap(
      defaultPlan.sections.first(where: { $0.index == 2 }))
    XCTAssertFalse(
      interviewSection.included,
      "a section that is not narrated must not be listed (or fingerprinted) as included")

    var options = PlanOptions()
    options.includeSections = ["2"]
    let rescued = try plan(fixture, options: options)
    XCTAssertEqual(rescued.chapters.map(\.title), ["Chapter One", "Author Interview"])
    XCTAssertTrue(
      try XCTUnwrap(rescued.sections.first(where: { $0.index == 2 })).included)
  }

  /// Regression (A Crown of Swords): a bonus excerpt anchors only its title
  /// page in the TOC while the excerpt's prose ships in a following file with
  /// no TOC entry and a generic "PROLOGUE" heading. The classifier must give
  /// that owned range the excerpt role itself — not just drop it during
  /// planning — so narration expectations (audiobook plan and ReadAloud
  /// coverage audits) agree that it is not primary narrative. A later
  /// TOC-anchored document ends the ownership.
  func testUnanchoredDocumentsAfterExcerptAnchorInheritExcerptRole() throws {
    var fixture = EPUBFixture()
    fixture.title = "Owned Excerpt Range"
    fixture.documents = [
      EPUBFixture.Document(
        id: "ch1", path: "OEBPS/ch1.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Chapter One</h1><p>Real prose.</p>")),
      EPUBFixture.Document(
        id: "excerpt", path: "OEBPS/excerpt.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<p>Excerpt of the next book.</p>")),
      EPUBFixture.Document(
        id: "excerptbody", path: "OEBPS/excerptbody.xhtml",
        xhtml: EPUBFixture.xhtml(
          body: "<h1>PROLOGUE</h1><p>Unanchored excerpt prose that reads like a chapter.</p>")),
      EPUBFixture.Document(
        id: "afterword", path: "OEBPS/afterword.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Afterword</h1><p>Anchored again.</p>")),
    ]
    fixture.navXHTML = EPUBFixture.nav(
      tocItems: """
        <li><a href="ch1.xhtml">Chapter One</a></li>
        <li><a href="excerpt.xhtml">Excerpt: The Next Book</a></li>
        <li><a href="afterword.xhtml">Afterword</a></li>
        """,
      landmarks: """
        <li><a epub:type="bodymatter" href="ch1.xhtml">Begin Reading</a></li>
        """)

    let result = try plan(fixture)
    let roleBySpineIndex = Dictionary(
      uniqueKeysWithValues: result.sections.map { ($0.index, $0.role) })
    XCTAssertEqual(roleBySpineIndex[1], .excerpt, "anchored excerpt title page")
    XCTAssertEqual(
      roleBySpineIndex[2], .excerpt,
      "unanchored prose owned by the excerpt anchor inherits the excerpt role")
    XCTAssertEqual(
      roleBySpineIndex[3], .afterword,
      "the next TOC-anchored document ends the owned range")
    XCTAssertEqual(result.chapters.map(\.title), ["Chapter One", "Afterword"])
  }

  func testExcludedStructuralAnchorDoesNotSwallowLaterBodySections() throws {
    var fixture = EPUBFixture()
    fixture.title = "Sparse Navigation"
    fixture.documents = [
      EPUBFixture.Document(
        id: "toc", path: "OEBPS/toc.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Contents</h1><p>Chapter One</p>")),
      EPUBFixture.Document(
        id: "body", path: "OEBPS/body.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Chapter One</h1><p>Body prose survives.</p>")),
    ]
    fixture.navXHTML = EPUBFixture.nav(
      tocItems: "<li><a href=\"toc.xhtml\">Table of Contents</a></li>")

    let result = try plan(fixture)
    XCTAssertEqual(result.chapters.map(\.title), ["Chapter One"])
    XCTAssertTrue(
      result.chapters[0].allParagraphs.flatMap(\.sentences).contains("Body prose survives."))
  }

  func testFragmentOnlyLandmarkDoesNotExcludeWholeDocument() throws {
    var fixture = EPUBFixture()
    fixture.title = "Shared Notes Document"
    fixture.documents = [
      EPUBFixture.Document(
        id: "body", path: "OEBPS/body.xhtml",
        xhtml: EPUBFixture.xhtml(
          body: """
            <section id="story"><h1>Chapter One</h1><p>Body prose survives.</p></section>
            <section id="notes"><h1>Notes</h1><p>Editorial apparatus.</p></section>
            """))
    ]
    fixture.navXHTML = EPUBFixture.nav(
      tocItems: "<li><a href=\"body.xhtml#story\">Chapter One</a></li>",
      landmarks: "<li><a epub:type=\"footnotes\" href=\"body.xhtml#notes\">Notes</a></li>")

    let result = try plan(fixture)
    XCTAssertNotEqual(result.sections.first?.role, .notes)
    XCTAssertTrue(
      result.chapters.flatMap(\.allParagraphs).flatMap(\.sentences)
        .contains("Body prose survives."))
  }

  func testExcludedStructuralAnchorPreservesPrefixBeforeNextFragment() throws {
    var fixture = EPUBFixture()
    fixture.title = "In-File Prefix"
    fixture.documents = [
      EPUBFixture.Document(
        id: "toc", path: "OEBPS/toc.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Contents</h1><p>Chapter One</p>")),
      EPUBFixture.Document(
        id: "body", path: "OEBPS/body.xhtml",
        xhtml: EPUBFixture.xhtml(
          body: """
            <p>Opening prose before the first named division.</p>
            <section id="chapter"><h1>Chapter One</h1><p>Named prose.</p></section>
            """)),
    ]
    fixture.navXHTML = EPUBFixture.nav(
      tocItems: """
        <li><a href="toc.xhtml">Table of Contents</a></li>
        <li><a href="body.xhtml#chapter">Chapter One</a></li>
        """)

    let result = try plan(fixture)
    let allText = result.chapters.flatMap(\.allParagraphs).flatMap(\.sentences)
    XCTAssertTrue(allText.contains("Opening prose before the first named division."))
    XCTAssertTrue(allText.contains("Named prose."))
  }

  func testPromotionalAndSampleSectionsAreExcludedConservativelyByTitle() throws {
    var fixture = EPUBFixture()
    fixture.title = "Publisher Back Matter"
    fixture.documents = [
      EPUBFixture.Document(
        id: "body", path: "OEBPS/body.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Chapter One</h1><p>The actual story.</p>")),
      EPUBFixture.Document(
        id: "buy", path: "OEBPS/buy.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Buy the Book</h1><p>Retail links.</p>")),
      EPUBFixture.Document(
        id: "sample", path: "OEBPS/sample.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Sample Chapter Two</h1><p>Another novel.</p>")),
      EPUBFixture.Document(
        id: "sample-child", path: "OEBPS/sample-child.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Chapter One</h1><p>Nested sample prose.</p>")),
    ]
    fixture.navXHTML = EPUBFixture.nav(
      tocItems: """
        <li><a href="body.xhtml">Chapter One</a></li>
        <li><a href="buy.xhtml">Buy the Book</a></li>
        <li><a href="sample.xhtml">Sample Chapter Two</a><ol>
          <li><a href="sample-child.xhtml">Chapter One</a></li>
        </ol></li>
        """)

    let result = try plan(fixture)
    XCTAssertEqual(result.chapters.map(\.title), ["Chapter One"])
    XCTAssertEqual(result.sections.first(where: { $0.index == 1 })?.role, .promotional)
    XCTAssertEqual(result.sections.first(where: { $0.index == 2 })?.role, .excerpt)
    XCTAssertEqual(result.sections.first(where: { $0.index == 3 })?.role, .excerpt)
  }

  func testMaxChaptersTruncates() throws {
    var options = PlanOptions()
    options.maxChapters = 2
    let plan = try plan(.mistbornShape(), options: options)
    XCTAssertEqual(plan.chapters.count, 2)
  }

  func testNonLinearSpineItemIsAuxiliaryUntilExplicitlyIncluded() throws {
    var fixture = EPUBFixture.spineOnlyShape()
    fixture.documents.append(
      EPUBFixture.Document(
        id: "aux", path: "OEBPS/aux.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Bonus</h1><p>Auxiliary prose.</p>"),
        linear: false))

    let defaultPlan = try plan(fixture)
    let auxiliary = try XCTUnwrap(defaultPlan.sections.first(where: { $0.index == 2 }))
    XCTAssertFalse(auxiliary.includedByDefault)
    XCTAssertFalse(defaultPlan.chapters.contains(where: { $0.title == "Bonus" }))

    var options = PlanOptions()
    options.includeSections = ["2"]
    let included = try plan(fixture, options: options)
    XCTAssertTrue(included.chapters.contains(where: { $0.title == "Bonus" }))
  }

  func testMisleadingFilenameCannotExcludeOrdinaryProse() throws {
    var fixture = EPUBFixture()
    fixture.title = "Discover"
    fixture.documents = [
      EPUBFixture.Document(
        id: "body", path: "OEBPS/discover.xhtml",
        xhtml: EPUBFixture.xhtml(body: "<h1>Discovery</h1><p>This is ordinary story prose.</p>"))
    ]
    let result = try plan(fixture)
    XCTAssertEqual(result.sections.first?.role, .unknown)
    XCTAssertTrue(result.sections.first?.included == true)
  }

  func testNonPositiveMaximumChapterCountIsRejected() throws {
    for value in [0, -1] {
      var options = PlanOptions()
      options.maxChapters = value
      let url = try EPUBFixture.spineOnlyShape().write()
      fixtureURLs.append(url)
      let publication = try EPUBImporter().load(url: url)
      XCTAssertThrowsError(try AudiobookPlanner.plan(publication: publication, options: options)) {
        error in
        guard case AudiobookPlanError.invalidMaximumChapterCount(value) = error else {
          return XCTFail("unexpected error: \(error)")
        }
      }
    }
  }

  func testAnnouncementsCanBeDisabledGlobally() throws {
    var options = PlanOptions()
    options.announceTitles = false
    let plan = try plan(.mistbornShape(), options: options)
    XCTAssertTrue(plan.chapters.allSatisfy { $0.announcement == nil })
    let chapter1 = try XCTUnwrap(plan.chapters.first(where: { $0.title == "Chapter 1" }))
    XCTAssertEqual(
      chapter1.paragraphs.first?.sentences, ["1"],
      "absorption is disabled with announcements: the body is narrated verbatim")
  }

  func testExcludingEverythingFails() throws {
    var options = PlanOptions()
    options.excludeSections = (0...5).map(String.init)
    let url = try EPUBFixture.mistbornShape().write()
    fixtureURLs.append(url)
    let publication = try EPUBImporter().load(url: url)
    XCTAssertThrowsError(try AudiobookPlanner.plan(publication: publication, options: options)) { error in
      guard case AudiobookPlanError.noNarratableContent = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }
}
